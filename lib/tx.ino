#include <Arduino.h>
#include <SPI.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <RadioLib.h>
#include <codec2.h>
#include <RingBuf.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <string.h>
#include <limits.h>

#define DEBUG_LOG(...) Serial.printf(__VA_ARGS__)

enum BleAudioType : uint8_t;
struct LoRaPacket;
struct TransportPacket;

SET_LOOP_TASK_STACK_SIZE(16 * 1024);

#define DEVICE_NAME                   "Heltec_Sender"
#define BLE_SERVICE_UUID              "12345678-1234-1234-1234-1234567890ab"
#define BLE_CHARACTERISTIC_UUID       "abcd1234-5678-1234-5678-abcdef123456"

#define LORA_FREQ_MHZ                 866.0
#define LORA_BW_KHZ                   250.0
#define LORA_SF                       7
#define LORA_CR                       5
#define LORA_SYNCWORD                 0x12
#define LORA_POWER_DBM                18
#define LORA_PREAMBLE                 8
#define LORA_PACKET_MAX_BYTES         80

// Realtime audio profile tuning. Keep these grouped so audio latency changes
// do not affect text/image transport settings.
#define AUDIO_LORA_INTER_PACKET_DELAY_MS     5
#define AUDIO_BLE_NOTIFY_INTERVAL_MS         10
#define AUDIO_BLE_NOTIFY_GAP_MS              0
#define AUDIO_STREAM_IDLE_STOP_MS            900
#define BLE_AUDIO_PAYLOAD_BYTES       236
#define BLE_AUDIO_NOTIFY_BYTES        236
#define RAW_AUDIO_BUFFER_BYTES        32768
#define COMPRESSED_BUFFER_BYTES       4096
#define DECODED_PCM_BUFFER_BYTES      8192
#define PCM_BUFFER_RESUME_BYTES       4096

#define TRANSPORT_LORA_INTER_PACKET_DELAY_MS 8

#define TRANSPORT_MAGIC_LO            0xB5
#define TRANSPORT_MAGIC_HI            0x62
#define TRANSPORT_PREFIX_BYTES        11
#define TRANSPORT_MAX_PACKET_BYTES    8192

#define FRAME_MAGIC                   0xB7
#define FRAME_HEADER_BYTES            6
#define FRAME_PAYLOAD_BYTES           (LORA_PACKET_MAX_BYTES - FRAME_HEADER_BYTES)

#define BLE_AUDIO_MAGIC               0xA5
#define BLE_AUDIO_HEADER_BYTES        8
#define TRANSPORT_BLE_NOTIFY_CHUNK_BYTES 180
#define TRANSPORT_BLE_NOTIFY_GAP_MS  15
#define BLE_PACKET_BUFFER_BYTES       8192

#define LORA_AUDIO_MAGIC              0xA6
#define LORA_AUDIO_TYPE_START         0x01
#define LORA_AUDIO_TYPE_DATA          0x02
#define LORA_AUDIO_TYPE_STOP          0x03
#define LORA_AUDIO_TARGET_BYTES       63

#define CODEC2_PCM_SAMPLES_PER_FRAME  320
#define CODEC2_COMPRESSED_BYTES_FRAME 7
#define TX_QUEUE_DEPTH                48
#define RX_QUEUE_DEPTH                48
#define AUDIO_RX_QUEUE_DEPTH          32

#define CORE_RADIO_BLE                0
#define CORE_CODEC                    1
#define TASK_NOTIFY_RX_BIT            0x01
#define TASK_NOTIFY_BLE_BIT           0x01
#define TASK_NOTIFY_AUDIO_RX_BIT      0x02

enum BleAudioType : uint8_t {
  BLE_AUDIO_START = 0x01,
  BLE_AUDIO_DATA  = 0x02,
  BLE_AUDIO_STOP  = 0x03,
};

struct LoRaPacket {
  uint16_t len;
  uint8_t postTxDelayMs;
  uint8_t data[LORA_PACKET_MAX_BYTES];
};

struct TransportPacket {
  uint16_t len;
  uint8_t data[TRANSPORT_MAX_PACKET_BYTES];
};

SX1262 radio(new Module(8, 14, 12, 13));

BLECharacteristic* gTransportChar = nullptr;
TaskHandle_t gRadioRxTaskHandle = nullptr;
TaskHandle_t gTransportAssemblerTaskHandle = nullptr;
TaskHandle_t gBleNotifyTaskHandle = nullptr;
TaskHandle_t gLoraTxTaskHandle = nullptr;
TaskHandle_t gAudioDecodeTaskHandle = nullptr;
TaskHandle_t gAudioEncodeTaskHandle = nullptr;

QueueHandle_t gLoraTxQueue = nullptr;
QueueHandle_t gTransportRxQueue = nullptr;
QueueHandle_t gAudioRxQueue = nullptr;

SemaphoreHandle_t gBleAssemblyMutex = nullptr;
SemaphoreHandle_t gRxAssemblyMutex = nullptr;
SemaphoreHandle_t gRawAudioMutex = nullptr;
SemaphoreHandle_t gCompressedMutex = nullptr;
SemaphoreHandle_t gDecodedPcmMutex = nullptr;
SemaphoreHandle_t gStreamStateMutex = nullptr;
SemaphoreHandle_t gBleNotifyMutex = nullptr;

volatile bool gDeviceConnected = false;
volatile bool gLoraIsrEnabled = true;
volatile bool gPttSessionActive = false;
volatile bool gPttStopRequested = false;
volatile bool gBleDownlinkStreamActive = false;

uint16_t gNextFrameId = 1;
uint8_t gBlePacketBuffer[BLE_PACKET_BUFFER_BYTES];
size_t gBlePacketLength = 0;
size_t gBlePacketExpected = 0;
uint8_t gCompleteTransportScratch[TRANSPORT_MAX_PACKET_BYTES];
uint8_t gBleTransportScratch[TRANSPORT_MAX_PACKET_BYTES];

uint16_t gRxFrameId = 0;
uint8_t gRxExpectedChunks = 0;
uint8_t gRxReceivedChunks = 0;
uint8_t gRxPacketBuffer[TRANSPORT_MAX_PACKET_BYTES];
size_t gRxPacketLength = 0;

RingBuf<uint8_t, RAW_AUDIO_BUFFER_BYTES> gRawAudioBuffer;
RingBuf<uint8_t, COMPRESSED_BUFFER_BYTES> gCompressedAudioBuffer;
RingBuf<uint8_t, DECODED_PCM_BUFFER_BYTES> gDecodedPcmBuffer;

struct CODEC2* gCodec2Enc = nullptr;
struct CODEC2* gCodec2Dec = nullptr;
int16_t* gDecodeOutSamples = nullptr;
size_t gCodec2SamplesPerFrame = 0;
size_t gCodec2CompressedBytesPerFrame = 0;
uint16_t gBleSequence = 0;
unsigned long gLastDecodedAudioMs = 0;

void resetBleAssembly() {
  xSemaphoreTake(gBleAssemblyMutex, portMAX_DELAY);
  gBlePacketLength = 0;
  gBlePacketExpected = 0;
  xSemaphoreGive(gBleAssemblyMutex);
}

void resetRxAssembly() {
  xSemaphoreTake(gRxAssemblyMutex, portMAX_DELAY);
  gRxFrameId = 0;
  gRxExpectedChunks = 0;
  gRxReceivedChunks = 0;
  gRxPacketLength = 0;
  xSemaphoreGive(gRxAssemblyMutex);
}

void clearRawAudioBuffer() {
  xSemaphoreTake(gRawAudioMutex, portMAX_DELAY);
  gRawAudioBuffer.clear();
  xSemaphoreGive(gRawAudioMutex);
}

void clearCompressedBuffer() {
  xSemaphoreTake(gCompressedMutex, portMAX_DELAY);
  gCompressedAudioBuffer.clear();
  xSemaphoreGive(gCompressedMutex);
}

void clearDecodedPcmBuffer() {
  xSemaphoreTake(gDecodedPcmMutex, portMAX_DELAY);
  gDecodedPcmBuffer.clear();
  xSemaphoreGive(gDecodedPcmMutex);
}

size_t compressedBufferSize() {
  size_t size = 0;
  xSemaphoreTake(gCompressedMutex, portMAX_DELAY);
  size = gCompressedAudioBuffer.size();
  xSemaphoreGive(gCompressedMutex);
  return size;
}

void trimDecodedPcmToLatest(size_t targetSize) {
  while (gDecodedPcmBuffer.size() > targetSize) {
    uint8_t discardByte = 0;
    gDecodedPcmBuffer.pop(discardByte);
  }
}

void markBleStreamActive(unsigned long decodedAtMs) {
  xSemaphoreTake(gStreamStateMutex, portMAX_DELAY);
  gBleDownlinkStreamActive = true;
  gLastDecodedAudioMs = decodedAtMs;
  xSemaphoreGive(gStreamStateMutex);
}

void stopBleStreamAndResetSequence() {
  xSemaphoreTake(gStreamStateMutex, portMAX_DELAY);
  gBleDownlinkStreamActive = false;
  gBleSequence = 0;
  xSemaphoreGive(gStreamStateMutex);
}

void getBleStreamState(bool* connected, bool* streamActive, uint16_t* sequence, unsigned long* decodedAtMs) {
  xSemaphoreTake(gStreamStateMutex, portMAX_DELAY);
  if (connected != nullptr) *connected = gDeviceConnected;
  if (streamActive != nullptr) *streamActive = gBleDownlinkStreamActive;
  if (sequence != nullptr) *sequence = gBleSequence;
  if (decodedAtMs != nullptr) *decodedAtMs = gLastDecodedAudioMs;
  xSemaphoreGive(gStreamStateMutex);
}

bool queueLoRaPacket(const uint8_t* data, uint16_t len, uint8_t postTxDelayMs) {
  if (len == 0 || len > LORA_PACKET_MAX_BYTES) return false;
  LoRaPacket pkt;
  pkt.len = len;
  pkt.postTxDelayMs = postTxDelayMs;
  memcpy(pkt.data, data, len);
  DEBUG_LOG("[TX] queueLoRaPacket len=%u delay=%u first=0x%02X\n", len, postTxDelayMs, data[0]);
  return xQueueSend(gLoraTxQueue, &pkt, pdMS_TO_TICKS(50)) == pdPASS;
}

bool queueBlePacket(const uint8_t* data, uint16_t len) {
  (void)data;
  (void)len;
  return false;
}

bool queueAudioControlPacket(uint8_t controlType) {
  const uint8_t packet[] = {LORA_AUDIO_MAGIC, controlType};
  return queueLoRaPacket(
    packet,
    sizeof(packet),
    AUDIO_LORA_INTER_PACKET_DELAY_MS
  );
}

bool pushRawAudioBytes(const uint8_t* data, size_t len) {
  bool trimmed = false;
  xSemaphoreTake(gRawAudioMutex, portMAX_DELAY);
  for (size_t i = 0; i < len; i++) {
    if (!gRawAudioBuffer.push(data[i])) {
      uint8_t discardByte = 0;
      gRawAudioBuffer.pop(discardByte);
      if (!gRawAudioBuffer.push(data[i])) {
        xSemaphoreGive(gRawAudioMutex);
        return trimmed;
      }
      trimmed = true;
    }
  }
  xSemaphoreGive(gRawAudioMutex);
  return trimmed;
}

bool popRawAudioFrame(int16_t* speechSamples) {
  xSemaphoreTake(gRawAudioMutex, portMAX_DELAY);
  const size_t bytesNeeded = gCodec2SamplesPerFrame * sizeof(int16_t);
  if (gRawAudioBuffer.size() < bytesNeeded) {
    xSemaphoreGive(gRawAudioMutex);
    return false;
  }

  for (size_t i = 0; i < gCodec2SamplesPerFrame; i++) {
    uint8_t low = 0;
    uint8_t high = 0;
    gRawAudioBuffer.pop(low);
    gRawAudioBuffer.pop(high);
    speechSamples[i] = (int16_t)((high << 8) | low);
  }
  xSemaphoreGive(gRawAudioMutex);
  return true;
}

bool pushCompressedFrame(const uint8_t* compressedBits) {
  xSemaphoreTake(gCompressedMutex, portMAX_DELAY);
  if ((COMPRESSED_BUFFER_BYTES - gCompressedAudioBuffer.size()) < gCodec2CompressedBytesPerFrame) {
    xSemaphoreGive(gCompressedMutex);
    return false;
  }
  for (size_t i = 0; i < gCodec2CompressedBytesPerFrame; i++) {
    if (!gCompressedAudioBuffer.push(compressedBits[i])) {
      xSemaphoreGive(gCompressedMutex);
      return false;
    }
  }
  xSemaphoreGive(gCompressedMutex);
  return true;
}

bool popCompressedPacket(LoRaPacket* pkt, size_t maxLen) {
  xSemaphoreTake(gCompressedMutex, portMAX_DELAY);
  const size_t available = gCompressedAudioBuffer.size();
  if (available < maxLen) {
    xSemaphoreGive(gCompressedMutex);
    return false;
  }
  pkt->len = maxLen + 2;
  pkt->data[0] = LORA_AUDIO_MAGIC;
  pkt->data[1] = LORA_AUDIO_TYPE_DATA;
  for (size_t i = 0; i < maxLen; i++) {
    gCompressedAudioBuffer.pop(pkt->data[i + 2]);
  }
  xSemaphoreGive(gCompressedMutex);
  return true;
}

bool popCompressedTailPacket(LoRaPacket* pkt, size_t maxLen) {
  xSemaphoreTake(gCompressedMutex, portMAX_DELAY);
  const size_t available = gCompressedAudioBuffer.size();
  if (available == 0) {
    xSemaphoreGive(gCompressedMutex);
    return false;
  }
  const size_t payloadLen = available > maxLen ? maxLen : available;
  pkt->len = payloadLen + 2;
  pkt->data[0] = LORA_AUDIO_MAGIC;
  pkt->data[1] = LORA_AUDIO_TYPE_DATA;
  for (size_t i = 0; i < payloadLen; i++) {
    gCompressedAudioBuffer.pop(pkt->data[i + 2]);
  }
  xSemaphoreGive(gCompressedMutex);
  return true;
}

void queueCompressedForLora(size_t payloadLen) {
  LoRaPacket pkt;
  while (popCompressedPacket(&pkt, payloadLen)) {
    pkt.postTxDelayMs = AUDIO_LORA_INTER_PACKET_DELAY_MS;
    if (xQueueSend(gLoraTxQueue, &pkt, portMAX_DELAY) != pdPASS) {
      break;
    }
  }
}

bool buildBleAudioHeader(BleAudioType type, uint8_t payloadLen, bool finalChunk, uint8_t* packet) {
  xSemaphoreTake(gStreamStateMutex, portMAX_DELAY);
  if (!gDeviceConnected || gTransportChar == nullptr) {
    xSemaphoreGive(gStreamStateMutex);
    return false;
  }
  packet[0] = BLE_AUDIO_MAGIC;
  packet[1] = (uint8_t)type;
  packet[2] = gBleSequence & 0xFF;
  packet[3] = (gBleSequence >> 8) & 0xFF;
  packet[4] = payloadLen;
  packet[5] = 8;
  packet[6] = 1;
  packet[7] = finalChunk ? 0x01 : 0x00;
  gBleSequence++;
  xSemaphoreGive(gStreamStateMutex);
  return true;
}

void notifyBleAudioPacket(BleAudioType type, const uint8_t* payload, uint8_t payloadLen, bool finalChunk) {
  if (gTransportChar == nullptr) return;
  uint8_t packet[BLE_AUDIO_HEADER_BYTES + BLE_AUDIO_NOTIFY_BYTES];
  if (!buildBleAudioHeader(type, payloadLen, finalChunk, packet)) return;
  if (payloadLen > 0 && payload != nullptr) {
    memcpy(packet + BLE_AUDIO_HEADER_BYTES, payload, payloadLen);
  }
  DEBUG_LOG("[TX] notify BLE audio type=%u payload=%u final=%u\n", (unsigned)type, payloadLen, finalChunk ? 1 : 0);
  if (gBleNotifyMutex == nullptr) return;
  xSemaphoreTake(gBleNotifyMutex, portMAX_DELAY);
  gTransportChar->setValue(packet, BLE_AUDIO_HEADER_BYTES + payloadLen);
  gTransportChar->notify();
  vTaskDelay(pdMS_TO_TICKS(AUDIO_BLE_NOTIFY_GAP_MS));
  xSemaphoreGive(gBleNotifyMutex);
}

void notifyBleTransportPacket(const uint8_t* packet, size_t packetLen) {
  if (!gDeviceConnected || gTransportChar == nullptr || gBleNotifyMutex == nullptr) return;
  DEBUG_LOG("[TX] notify transport bytes=%u type=0x%02X\n", (unsigned)packetLen, packetLen > 3 ? packet[3] : 0x00);
  xSemaphoreTake(gBleNotifyMutex, portMAX_DELAY);
  size_t offset = 0;
  while (offset < packetLen) {
    const size_t chunkLen = (packetLen - offset) > TRANSPORT_BLE_NOTIFY_CHUNK_BYTES
        ? TRANSPORT_BLE_NOTIFY_CHUNK_BYTES
        : (packetLen - offset);
    gTransportChar->setValue(const_cast<uint8_t*>(packet + offset), chunkLen);
    gTransportChar->notify();
    offset += chunkLen;
    vTaskDelay(pdMS_TO_TICKS(TRANSPORT_BLE_NOTIFY_GAP_MS));
  }
  xSemaphoreGive(gBleNotifyMutex);
}

void fragmentAndQueueTransportPacket(const uint8_t* packet, size_t packetLen) {
  if (packetLen < TRANSPORT_PREFIX_BYTES || packetLen > TRANSPORT_MAX_PACKET_BYTES) return;
  const uint16_t frameId = gNextFrameId++;
  const uint8_t totalChunks = (packetLen + FRAME_PAYLOAD_BYTES - 1) / FRAME_PAYLOAD_BYTES;
  DEBUG_LOG("[TX] fragment transport bytes=%u frameId=%u chunks=%u type=0x%02X\n",
    (unsigned)packetLen, frameId, totalChunks, packet[3]);
  for (uint8_t chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
    const size_t payloadOffset = chunkIndex * FRAME_PAYLOAD_BYTES;
    const size_t remaining = packetLen - payloadOffset;
    const uint8_t payloadLen = remaining > FRAME_PAYLOAD_BYTES ? FRAME_PAYLOAD_BYTES : remaining;
    uint8_t frame[LORA_PACKET_MAX_BYTES];
    frame[0] = FRAME_MAGIC;
    frame[1] = frameId & 0xFF;
    frame[2] = (frameId >> 8) & 0xFF;
    frame[3] = chunkIndex;
    frame[4] = totalChunks;
    frame[5] = payloadLen;
    memcpy(frame + FRAME_HEADER_BYTES, packet + payloadOffset, payloadLen);
    if (!queueLoRaPacket(frame, FRAME_HEADER_BYTES + payloadLen, TRANSPORT_LORA_INTER_PACKET_DELAY_MS)) break;
  }
}

void handleCompleteTransportPacket(const uint8_t* packet, size_t packetLen) {
  if (!gDeviceConnected || gTransportChar == nullptr) return;
  notifyBleTransportPacket(packet, packetLen);
}

void appendTransportBleBytes(const uint8_t* data, size_t len) {
  DEBUG_LOG("[TX] BLE transport write bytes=%u first=0x%02X\n", (unsigned)len, len > 0 ? data[0] : 0x00);
  xSemaphoreTake(gBleAssemblyMutex, portMAX_DELAY);
  for (size_t i = 0; i < len; i++) {
    if (gBlePacketLength >= BLE_PACKET_BUFFER_BYTES) {
      gBlePacketLength = 0;
      gBlePacketExpected = 0;
    }
    gBlePacketBuffer[gBlePacketLength++] = data[i];

    if (gBlePacketLength >= TRANSPORT_PREFIX_BYTES && gBlePacketExpected == 0) {
      if (gBlePacketBuffer[0] != TRANSPORT_MAGIC_LO || gBlePacketBuffer[1] != TRANSPORT_MAGIC_HI) {
        memmove(gBlePacketBuffer, gBlePacketBuffer + 1, gBlePacketLength - 1);
        gBlePacketLength--;
        continue;
      }
      const uint8_t headerLen = gBlePacketBuffer[4];
      const uint16_t payloadLen = gBlePacketBuffer[5] | (gBlePacketBuffer[6] << 8);
      gBlePacketExpected = TRANSPORT_PREFIX_BYTES + headerLen + payloadLen;
      if (gBlePacketExpected > TRANSPORT_MAX_PACKET_BYTES) {
        gBlePacketLength = 0;
        gBlePacketExpected = 0;
      }
    }

    if (gBlePacketExpected > 0 && gBlePacketLength == gBlePacketExpected) {
      const size_t packetLen = gBlePacketExpected;
      memcpy(gBleTransportScratch, gBlePacketBuffer, packetLen);
      DEBUG_LOG("[TX] BLE transport assembled bytes=%u type=0x%02X\n", (unsigned)packetLen, gBleTransportScratch[3]);
      gBlePacketLength = 0;
      gBlePacketExpected = 0;
      xSemaphoreGive(gBleAssemblyMutex);
      fragmentAndQueueTransportPacket(gBleTransportScratch, packetLen);
      xSemaphoreTake(gBleAssemblyMutex, portMAX_DELAY);
    }
  }
  xSemaphoreGive(gBleAssemblyMutex);
}

void handleIncomingBleAudioPacket(const uint8_t* bytes, size_t packetLen) {
  if (packetLen < BLE_AUDIO_HEADER_BYTES) return;
  const uint8_t packetType = bytes[1];
  const uint8_t payloadLen = bytes[4];
  const size_t availablePayload = packetLen - BLE_AUDIO_HEADER_BYTES;
  const size_t bytesToCopy = payloadLen < availablePayload ? payloadLen : availablePayload;

  if (packetType == BLE_AUDIO_START) {
    DEBUG_LOG("[TX] BLE audio START\n");
    clearRawAudioBuffer();
    clearCompressedBuffer();
    gPttSessionActive = true;
    gPttStopRequested = false;
    queueAudioControlPacket(LORA_AUDIO_TYPE_START);
    return;
  }
  if (packetType == BLE_AUDIO_STOP) {
    DEBUG_LOG("[TX] BLE audio STOP\n");
    gPttSessionActive = false;
    gPttStopRequested = true;
    return;
  }
  if (packetType != BLE_AUDIO_DATA) return;
  if (!gPttSessionActive) {
    DEBUG_LOG("[TX] BLE audio DATA dropped while inactive bytes=%u\n", (unsigned)bytesToCopy);
    return;
  }
  pushRawAudioBytes(bytes + BLE_AUDIO_HEADER_BYTES, bytesToCopy);
}

void pushDecodedFrameToPcmBufferAndNotify() {
  if (!gDeviceConnected) {
    stopBleStreamAndResetSequence();
    clearDecodedPcmBuffer();
    return;
  }

  const uint8_t* pcmBytes = reinterpret_cast<const uint8_t*>(gDecodeOutSamples);
  const size_t pcmByteCount = gCodec2SamplesPerFrame * sizeof(int16_t);
  xSemaphoreTake(gDecodedPcmMutex, portMAX_DELAY);
  if (gDecodedPcmBuffer.size() > (DECODED_PCM_BUFFER_BYTES - pcmByteCount)) {
    trimDecodedPcmToLatest(PCM_BUFFER_RESUME_BYTES);
  }
  for (size_t i = 0; i < pcmByteCount; i++) {
    if (!gDecodedPcmBuffer.push(pcmBytes[i])) {
      uint8_t discard = 0;
      gDecodedPcmBuffer.pop(discard);
      gDecodedPcmBuffer.push(pcmBytes[i]);
    }
  }
  xSemaphoreGive(gDecodedPcmMutex);

  markBleStreamActive(millis());
  if (gBleNotifyTaskHandle != nullptr) {
    xTaskNotify(gBleNotifyTaskHandle, TASK_NOTIFY_BLE_BIT, eSetBits);
  }
}

class TransportCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    std::string value = pChar->getValue();
    if (value.empty()) return;
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(value.data());
    const size_t packetLen = value.size();
    DEBUG_LOG("[TX] BLE onWrite bytes=%u first=0x%02X\n", (unsigned)packetLen, bytes[0]);
    if (packetLen >= BLE_AUDIO_HEADER_BYTES && bytes[0] == BLE_AUDIO_MAGIC) {
      handleIncomingBleAudioPacket(bytes, packetLen);
      return;
    }
    appendTransportBleBytes(bytes, packetLen);
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    gDeviceConnected = true;
    Serial.println("BLE client connected");
  }
  void onDisconnect(BLEServer* pServer) override {
    gDeviceConnected = false;
    gPttSessionActive = false;
    gPttStopRequested = false;
    resetBleAssembly();
    resetRxAssembly();
    stopBleStreamAndResetSequence();
    clearRawAudioBuffer();
    clearCompressedBuffer();
    clearDecodedPcmBuffer();
    Serial.println("BLE client disconnected");
    pServer->getAdvertising()->start();
  }
};

void ARDUINO_ISR_ATTR onLoraDataAvailableIsr() {
  if (!gLoraIsrEnabled || gRadioRxTaskHandle == nullptr) return;
  BaseType_t higherPriorityTaskWoken = pdFALSE;
  xTaskNotifyFromISR(gRadioRxTaskHandle, TASK_NOTIFY_RX_BIT, eSetBits, &higherPriorityTaskWoken);
  if (higherPriorityTaskWoken == pdTRUE) portYIELD_FROM_ISR();
}

void loraRxTask(void* param) {
  LoRaPacket pkt;
  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0, ULONG_MAX, &bits, portMAX_DELAY);
    if ((bits & TASK_NOTIFY_RX_BIT) == 0) continue;

    memset(&pkt, 0, sizeof(pkt));
    pkt.len = radio.getPacketLength();
    if (pkt.len > 0 && pkt.len <= LORA_PACKET_MAX_BYTES) {
      const int state = radio.readData(pkt.data, pkt.len);
      if (state == RADIOLIB_ERR_NONE) {
        DEBUG_LOG("[TX] LoRa RX len=%u first=0x%02X\n", pkt.len, pkt.data[0]);
        if (pkt.data[0] == FRAME_MAGIC) {
          if (xQueueSend(gTransportRxQueue, &pkt, pdMS_TO_TICKS(10)) == pdPASS &&
              gTransportAssemblerTaskHandle != nullptr) {
            xTaskNotify(gTransportAssemblerTaskHandle, TASK_NOTIFY_RX_BIT, eSetBits);
          }
        } else if (pkt.data[0] == LORA_AUDIO_MAGIC) {
          if (xQueueSend(gAudioRxQueue, &pkt, pdMS_TO_TICKS(10)) == pdPASS &&
              gAudioDecodeTaskHandle != nullptr) {
            xTaskNotify(gAudioDecodeTaskHandle, TASK_NOTIFY_AUDIO_RX_BIT, eSetBits);
          }
        }
      }
    }
    radio.startReceive();
  }
}

void transportAssemblerTask(void* param) {
  LoRaPacket pkt;
  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0, ULONG_MAX, &bits, portMAX_DELAY);
    if ((bits & TASK_NOTIFY_RX_BIT) == 0) continue;

    while (xQueueReceive(gTransportRxQueue, &pkt, 0) == pdPASS) {
      if (pkt.len < FRAME_HEADER_BYTES || pkt.data[0] != FRAME_MAGIC) continue;
      const uint16_t frameId = pkt.data[1] | (pkt.data[2] << 8);
      const uint8_t chunkIndex = pkt.data[3];
      const uint8_t totalChunks = pkt.data[4];
      const uint8_t payloadLen = pkt.data[5];
      if (payloadLen + FRAME_HEADER_BYTES != pkt.len || totalChunks == 0) {
        resetRxAssembly();
        continue;
      }

      xSemaphoreTake(gRxAssemblyMutex, portMAX_DELAY);
      if (gRxFrameId != frameId || chunkIndex == 0) {
        gRxFrameId = frameId;
        gRxExpectedChunks = totalChunks;
        gRxReceivedChunks = 0;
        gRxPacketLength = 0;
      }
      if (chunkIndex >= gRxExpectedChunks || gRxPacketLength + payloadLen > TRANSPORT_MAX_PACKET_BYTES) {
        gRxFrameId = 0;
        gRxExpectedChunks = 0;
        gRxReceivedChunks = 0;
        gRxPacketLength = 0;
        xSemaphoreGive(gRxAssemblyMutex);
        continue;
      }

      memcpy(gRxPacketBuffer + gRxPacketLength, pkt.data + FRAME_HEADER_BYTES, payloadLen);
      gRxPacketLength += payloadLen;
      gRxReceivedChunks++;

      const bool complete = gRxReceivedChunks == gRxExpectedChunks;
      size_t packetLen = 0;
      if (complete) {
        packetLen = gRxPacketLength;
        memcpy(gCompleteTransportScratch, gRxPacketBuffer, packetLen);
        gRxFrameId = 0;
        gRxExpectedChunks = 0;
        gRxReceivedChunks = 0;
        gRxPacketLength = 0;
      }
      xSemaphoreGive(gRxAssemblyMutex);

      if (complete) {
        DEBUG_LOG("[TX] transport complete bytes=%u\n", (unsigned)packetLen);
        handleCompleteTransportPacket(gCompleteTransportScratch, packetLen);
      }
    }
  }
}

void audioDecodeTask(void* param) {
  LoRaPacket pkt;
  uint8_t pendingCompressed[CODEC2_COMPRESSED_BYTES_FRAME];
  size_t pendingCompressedLen = 0;
  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0, ULONG_MAX, &bits, portMAX_DELAY);
    if ((bits & TASK_NOTIFY_AUDIO_RX_BIT) == 0) continue;

    while (xQueueReceive(gAudioRxQueue, &pkt, 0) == pdPASS) {
      if (pkt.len <= 1 || pkt.data[0] != LORA_AUDIO_MAGIC) continue;
      const uint8_t packetType = pkt.data[1];
      if (packetType == LORA_AUDIO_TYPE_START) {
        pendingCompressedLen = 0;
        clearDecodedPcmBuffer();
        notifyBleAudioPacket(BLE_AUDIO_START, nullptr, 0, false);
        continue;
      }
      if (packetType == LORA_AUDIO_TYPE_STOP) {
        notifyBleAudioPacket(BLE_AUDIO_STOP, nullptr, 0, false);
        stopBleStreamAndResetSequence();
        continue;
      }
      if (packetType != LORA_AUDIO_TYPE_DATA || pkt.len <= 2) continue;
      size_t offset = 2;
      const size_t len = pkt.len;

      if (pendingCompressedLen > 0) {
        const size_t needed = gCodec2CompressedBytesPerFrame - pendingCompressedLen;
        const size_t toCopy = (len - offset) < needed ? (len - offset) : needed;
        memcpy(&pendingCompressed[pendingCompressedLen], &pkt.data[offset], toCopy);
        pendingCompressedLen += toCopy;
        offset += toCopy;
        if (pendingCompressedLen == gCodec2CompressedBytesPerFrame) {
          codec2_decode(gCodec2Dec, gDecodeOutSamples, pendingCompressed);
          pushDecodedFrameToPcmBufferAndNotify();
          pendingCompressedLen = 0;
        } else {
          continue;
        }
      }

      while (offset + gCodec2CompressedBytesPerFrame <= len) {
        codec2_decode(gCodec2Dec, gDecodeOutSamples, &pkt.data[offset]);
        pushDecodedFrameToPcmBufferAndNotify();
        offset += gCodec2CompressedBytesPerFrame;
      }

      const size_t tailBytes = len - offset;
      if (tailBytes > 0) {
        memcpy(pendingCompressed, &pkt.data[offset], tailBytes);
        pendingCompressedLen = tailBytes;
      }
    }
  }
}

void audioEncodeTask(void* param) {
  int16_t speechSamples[CODEC2_PCM_SAMPLES_PER_FRAME];
  uint8_t compressedBits[CODEC2_COMPRESSED_BYTES_FRAME];
  while (true) {
    if (popRawAudioFrame(speechSamples)) {
      codec2_encode(gCodec2Enc, compressedBits, speechSamples);
      while ((COMPRESSED_BUFFER_BYTES - compressedBufferSize()) < gCodec2CompressedBytesPerFrame) {
        queueCompressedForLora(LORA_AUDIO_TARGET_BYTES);
        vTaskDelay(pdMS_TO_TICKS(1));
      }
      if (pushCompressedFrame(compressedBits)) {
        queueCompressedForLora(LORA_AUDIO_TARGET_BYTES);
      }
    } else if (gPttStopRequested) {
      DEBUG_LOG("[TX] draining compressed tail\n");
      LoRaPacket pkt;
      while (popCompressedTailPacket(&pkt, LORA_AUDIO_TARGET_BYTES)) {
        pkt.postTxDelayMs = AUDIO_LORA_INTER_PACKET_DELAY_MS;
        if (xQueueSend(gLoraTxQueue, &pkt, portMAX_DELAY) != pdPASS) break;
      }
      queueAudioControlPacket(LORA_AUDIO_TYPE_STOP);
      clearCompressedBuffer();
      clearRawAudioBuffer();
      gPttStopRequested = false;
    } else {
      vTaskDelay(pdMS_TO_TICKS(2));
    }
  }
}

void bleNotifyTask(void* param) {
  uint8_t audioPayload[BLE_AUDIO_NOTIFY_BYTES];
  unsigned long lastBleNotifyMs = 0;

  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0, ULONG_MAX, &bits, pdMS_TO_TICKS(AUDIO_BLE_NOTIFY_INTERVAL_MS));

    bool connected = false;
    bool streamActive = false;
    uint16_t sequence = 0;
    unsigned long decodedAtMs = 0;
    getBleStreamState(&connected, &streamActive, &sequence, &decodedAtMs);
    if (!connected) continue;

    size_t decodedSize = 0;
    xSemaphoreTake(gDecodedPcmMutex, portMAX_DELAY);
    decodedSize = gDecodedPcmBuffer.size();
    xSemaphoreGive(gDecodedPcmMutex);

    if (decodedSize >= BLE_AUDIO_NOTIFY_BYTES &&
        millis() - lastBleNotifyMs >= AUDIO_BLE_NOTIFY_INTERVAL_MS) {
      xSemaphoreTake(gDecodedPcmMutex, portMAX_DELAY);
      for (uint16_t i = 0; i < BLE_AUDIO_NOTIFY_BYTES; i++) {
        gDecodedPcmBuffer.pop(audioPayload[i]);
      }
      xSemaphoreGive(gDecodedPcmMutex);

      if (streamActive && sequence == 0) {
        DEBUG_LOG("[TX] BLE notify audio stream active\n");
      }
      notifyBleAudioPacket(BLE_AUDIO_DATA, audioPayload, BLE_AUDIO_NOTIFY_BYTES, false);
      lastBleNotifyMs = millis();
    }

    getBleStreamState(nullptr, &streamActive, nullptr, &decodedAtMs);
    if (streamActive &&
        millis() - decodedAtMs > AUDIO_STREAM_IDLE_STOP_MS &&
        millis() - lastBleNotifyMs >= AUDIO_BLE_NOTIFY_INTERVAL_MS) {
      while (true) {
        size_t chunkLen = 0;
        size_t remainingAfter = 0;
        xSemaphoreTake(gDecodedPcmMutex, portMAX_DELAY);
        const size_t remaining = gDecodedPcmBuffer.size();
        if (remaining > 0) {
          chunkLen = remaining > BLE_AUDIO_NOTIFY_BYTES ? BLE_AUDIO_NOTIFY_BYTES : remaining;
          for (size_t i = 0; i < chunkLen; i++) {
            gDecodedPcmBuffer.pop(audioPayload[i]);
          }
          remainingAfter = gDecodedPcmBuffer.size();
        }
        xSemaphoreGive(gDecodedPcmMutex);
        if (chunkLen == 0) break;
        notifyBleAudioPacket(BLE_AUDIO_DATA, audioPayload, chunkLen, remainingAfter == 0);
      }
      stopBleStreamAndResetSequence();
      lastBleNotifyMs = millis();
    }
  }
}

void loraTxTask(void* param) {
  LoRaPacket pkt;
  while (true) {
    if (xQueueReceive(gLoraTxQueue, &pkt, portMAX_DELAY) != pdPASS) continue;
    gLoraIsrEnabled = false;
    DEBUG_LOG("[TX] LoRa TX len=%u first=0x%02X\n", pkt.len, pkt.data[0]);
    const int txState = radio.transmit(pkt.data, pkt.len);
    if (txState != RADIOLIB_ERR_NONE) {
      Serial.printf("LoRa TX failed code=%d\n", txState);
    }
    radio.startReceive();
    gLoraIsrEnabled = true;
    vTaskDelay(pdMS_TO_TICKS(pkt.postTxDelayMs));
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.printf("%s hybrid relay boot\n", DEVICE_NAME);

  const int state = radio.begin(LORA_FREQ_MHZ, LORA_BW_KHZ, LORA_SF, LORA_CR, LORA_SYNCWORD, LORA_POWER_DBM, LORA_PREAMBLE);
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("Radio init failed code=%d\n", state);
    while (1) delay(1000);
  }
  radio.setCurrentLimit(120.0);
  radio.setDio1Action(onLoraDataAvailableIsr);

  gBleAssemblyMutex = xSemaphoreCreateMutex();
  gRxAssemblyMutex = xSemaphoreCreateMutex();
  gRawAudioMutex = xSemaphoreCreateMutex();
  gCompressedMutex = xSemaphoreCreateMutex();
  gDecodedPcmMutex = xSemaphoreCreateMutex();
  gStreamStateMutex = xSemaphoreCreateMutex();
  gBleNotifyMutex = xSemaphoreCreateMutex();

  gLoraTxQueue = xQueueCreate(TX_QUEUE_DEPTH, sizeof(LoRaPacket));
  gTransportRxQueue = xQueueCreate(RX_QUEUE_DEPTH, sizeof(LoRaPacket));
  gAudioRxQueue = xQueueCreate(AUDIO_RX_QUEUE_DEPTH, sizeof(LoRaPacket));
  gCodec2Enc = codec2_create(CODEC2_MODE_1300);
  gCodec2Dec = codec2_create(CODEC2_MODE_1300);
  if (gCodec2Enc != nullptr) {
    gCodec2SamplesPerFrame = (size_t)codec2_samples_per_frame(gCodec2Enc);
    gCodec2CompressedBytesPerFrame = (size_t)((codec2_bits_per_frame(gCodec2Enc) + 7) / 8);
  }
  gDecodeOutSamples = (int16_t*)malloc(sizeof(int16_t) * gCodec2SamplesPerFrame);

  if (!gBleAssemblyMutex || !gRxAssemblyMutex || !gRawAudioMutex ||
      !gCompressedMutex || !gDecodedPcmMutex || !gStreamStateMutex || !gBleNotifyMutex ||
      !gLoraTxQueue || !gTransportRxQueue || !gAudioRxQueue ||
      !gCodec2Enc || !gCodec2Dec || !gDecodeOutSamples ||
      gCodec2SamplesPerFrame == 0 || gCodec2SamplesPerFrame > CODEC2_PCM_SAMPLES_PER_FRAME ||
      gCodec2CompressedBytesPerFrame == 0 || gCodec2CompressedBytesPerFrame > CODEC2_COMPRESSED_BYTES_FRAME) {
    Serial.println("Resource init failed");
    while (1) delay(1000);
  }

  Serial.printf("[TX] Codec2 geometry samples=%u bytes=%u\n",
    (unsigned)gCodec2SamplesPerFrame,
    (unsigned)gCodec2CompressedBytesPerFrame);

  BLEDevice::init(DEVICE_NAME);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService* service = server->createService(BLE_SERVICE_UUID);

  gTransportChar = service->createCharacteristic(
    BLE_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  gTransportChar->setCallbacks(new TransportCallbacks());
  gTransportChar->addDescriptor(new BLE2902());

  service->start();
  server->getAdvertising()->start();

  xTaskCreatePinnedToCore(loraRxTask, "lora_rx_task", 8192, NULL, 5, &gRadioRxTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(transportAssemblerTask, "transport_assembler_task", 8192, NULL, 4, &gTransportAssemblerTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(bleNotifyTask, "ble_notify_task", 8192, NULL, 3, &gBleNotifyTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(loraTxTask, "lora_tx_task", 8192, NULL, 4, &gLoraTxTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(audioEncodeTask, "audio_encode_task", 24576, NULL, 3, &gAudioEncodeTaskHandle, CORE_CODEC);
  xTaskCreatePinnedToCore(audioDecodeTask, "audio_decode_task", 24576, NULL, 3, &gAudioDecodeTaskHandle, CORE_CODEC);

  radio.startReceive();
}

void loop() {
  delay(20);
}
