
## 1. System Roles

- `Phone app`
  Sends and receives binary transport packets over BLE.
- `Heltec gateway`
  Bridges BLE packets from the phone to LoRa frames and bridges received LoRa frames back to BLE notifications.
- `Other Heltec gateway`
  Receives LoRa frames, reassembles packets, and notifies its connected phone over BLE.

The current `heltec1.ino` and `heltec2.ino` sketches are almost the same relay design with different BLE device names:

- `Heltec_1`
- `Heltec_2`

## 2. Current Security Model



- BLE packets are sent as raw bytes.
- LoRa frames are sent as raw bytes.
- CRC32 is used to detect corrupted packets.
- Codec2 audio encoding compresses voice data, but it is not encryption.




## 3. BLE Connection

The Flutter app scans for BLE devices whose name contains `Heltec`.

The Heltec sketches expose:

- BLE service UUID: `12345678-1234-1234-1234-1234567890ab`
- BLE characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456`

The characteristic supports:

- write
- write without response
- notify

The app writes outgoing transport packets to this characteristic. The Heltec board notifies incoming transport packets back to the app on the same characteristic.

## 4. App Transport Packet

The Flutter app wraps text, image, recorded audio, and realtime audio control data in binary transport packets.

### Packet Layout

- `magicLo`: 1 byte, `0xB5`
- `magicHi`: 1 byte, `0x62`
- `version`: 1 byte
- `type`: 1 byte
- `headerLen`: 1 byte
- `payloadLen`: 2 bytes, little-endian
- `crc32`: 4 bytes, little-endian
- `header`: `headerLen` bytes
- `payload`: `payloadLen` bytes

### CRC Scope

CRC32 is computed over:

- `version`
- `type`
- `headerLen`
- `payloadLen`
- `header`
- `payload`

The receiver validates CRC before accepting the packet. A CRC failure means the packet is discarded.

## 5. Transport Packet Types

The app uses packet types for:

- text message
- text start/stop
- text chunk
- text ACK/NACK/delivery ACK
- image start
- image chunk
- image done
- image ACK/NACK/delivery ACK
- audio chunk
- audio done
- audio ACK/NACK/delivery ACK
- realtime audio start
- realtime audio data
- realtime audio stop

Packet type values are defined in `lib/main.dart`.

## 6. LoRa Frame Format

The Heltec board fragments one app transport packet into multiple LoRa frames.

### Frame Layout

- `frameMagic`: 1 byte, `0xB7`
- `frameId`: 2 bytes, little-endian
- `chunkIndex`: 1 byte
- `totalChunks`: 1 byte
- `payloadLen`: 1 byte
- `payload`: transport packet bytes

The payload is copied directly from the app transport packet. It is not encrypted before LoRa transmission.

## 7. Heltec Bridge Flow

Outgoing path:

1. Phone writes a binary transport packet over BLE.
2. Heltec receives BLE bytes.
3. Heltec reassembles the full transport packet.
4. Heltec fragments the packet into LoRa frames.
5. Heltec transmits each LoRa frame using RadioLib.

Incoming path:

1. Heltec receives LoRa frames.
2. Heltec reassembles the transport packet.
3. Heltec sends the full packet to the phone using BLE notify.
4. Flutter app decodes the packet and validates CRC.
5. Flutter app stores or displays the completed message.

## 8. Text Transfer

Small text can be sent in one binary packet.

Longer text is sent as:

1. text start
2. text chunks
3. text done
4. delivery ACK

Each text chunk includes a CRC for that chunk. The final done packet includes a CRC for the complete text.

## 9. Image Transfer

Images are compressed by the app before sending.

Image transfer uses:

1. image start
2. image chunks
3. missing chunk requests when needed
4. image done
5. delivery ACK

Each image chunk includes a CRC. The image done packet includes the final image CRC.

## 10. Audio Transfer

Recorded audio is converted from WAV/PCM and encoded with Codec2 before transfer.

Audio transfer uses:

1. audio chunks
2. audio done
3. chunk ACK/NACK
4. delivery ACK

Codec2 reduces audio size for LoRa transfer, but it does not encrypt the audio.

## 11. Realtime Audio

Realtime audio uses a separate packet marker:

- BLE audio marker: `0xA5`
- LoRa audio marker: `0xA6`

Realtime audio packet types:

- start: `0x01`
- audio data: `0x02`
- stop: `0x03`

The realtime audio path sends encoded/compressed audio frames through the Heltec bridge. This data is also not encrypted.

## 12. Storage Rules

The phone stores messages in SQLite.

Message records include:

- `id`
- `text` or local file path
- `timestamp`
- `status`
- `fromUser`
- `isImage`
- `conversationId`
- retry metadata

Images and audio are stored as local files. The database stores their file paths.
