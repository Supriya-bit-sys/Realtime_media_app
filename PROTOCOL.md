# LoRa Voice App Protocol

This document defines the intended architecture and packet protocol for the app, BLE gateways, and LoRa server.

## 1. System Roles

- `Phone app`
  Sends and receives raw binary transport packets over BLE.
- `BLE gateway Heltec`
  Bridges phone BLE traffic to LoRa, performs encryption/decryption, chunking, ACK handling, and peer session setup.
- `LoRa server Heltec`
  Registers gateways, tracks presence, answers discovery and key requests, and relays opaque encrypted peer traffic.

## 2. Trust Model

- BLE between phone and gateway is raw binary and is not encrypted.
- Encryption starts at the Heltec gateway.
- Server traffic is encrypted between gateway and server after registration.
- Peer message traffic is end-to-end encrypted between sender gateway and receiver gateway.
- The server relays peer ciphertext and should not need to decrypt peer message content.

## 3. Registration And Identity

Each gateway has:

- `nodeId`
- `name`
- `publicKey`
- `privateKey`

On first boot or after flash:

1. Gateway loads or generates its keypair.
2. Gateway sends `REGISTER(nodeId, name, publicKey)` to server.
3. Server stores the gateway identity.
4. Server replies with `REGISTER_ACK`.
5. Gateway then sends presence updates when phone BLE connect state changes.

Notes:

- Registration may remain unencrypted because the public key is not secret.
- Private keys never leave the gateway.

## 4. Discovery And Peering

`Peering` means selecting a LoRa chat partner and preparing a secure session key.

Flow:

1. Phone scans nearby BLE devices.
2. Phone connects to one gateway.
3. Phone sends gateway register/bootstrap command over BLE.
4. Gateway registers with server if needed.
5. Phone asks gateway to discover LoRa peers.
6. Gateway sends `DISCOVER_REQ` to server.
7. Server returns available peers with online status.
8. Phone shows discovered peers.
9. User selects one peer for chat.
10. Gateway requests that peer's public key from server.
11. Server returns peer public key plus server signature.
12. Gateway verifies the signature.
13. Gateway derives a shared session key with ECDH.
14. Gateway marks the peer as ready for secure chat.

Receiver behavior:

- A receiver gateway accepts secure peer packets for the currently selected and key-synced peer.
- In the current implementation, one secure chat route is active at a time on a gateway.
- Receiver phone does not need to connect to sender phone.
- Receiver phone only needs BLE connection to its own gateway.

## 5. End-To-End Message Path

For text, image, and audio:

1. Phone creates a raw binary transport packet.
2. Phone writes the transport packet to its gateway over BLE.
3. Gateway validates packet CRC.
4. Gateway splits the transport packet into LoRa frames.
5. Gateway encrypts peer payload using the selected peer session key.
6. Gateway wraps encrypted peer payload for server relay.
7. Server forwards the opaque encrypted peer packet.
8. Receiver gateway decrypts peer payload.
9. Receiver gateway reassembles LoRa frames into one transport packet.
10. Receiver gateway notifies its phone over BLE with the raw binary transport packet.
11. Receiver phone validates CRC, reassembles message data if needed, and stores only when complete.

## 6. BLE Transport Packet

Phone and gateway communicate using one binary transport format.

The gateway treats app transport packet types as opaque raw-binary payloads. It validates, chunks, encrypts, relays, decrypts, reassembles, and notifies, but it does not interpret text/image/audio semantics.

### Packet Layout

- `magicLo` : 1 byte
- `magicHi` : 1 byte
- `version` : 1 byte
- `type` : 1 byte
- `headerLen` : 1 byte
- `payloadLen` : 2 bytes, little-endian
- `crc32` : 4 bytes, little-endian
- `header` : `headerLen` bytes
- `payload` : `payloadLen` bytes

### CRC Scope

CRC32 is computed over:

- `version`
- `type`
- `headerLen`
- `payloadLen`
- `header`
- `payload`

### BLE Chunking

- Max BLE notify/write chunk: about `240` bytes
- A transport packet may span multiple BLE chunks.
- BLE is treated as lossless.
- Reassembly is done before packet decoding.

## 7. LoRa Frame Format

Each transport packet is split into LoRa frames.

### Frame Layout

- `frameMagic` : 1 byte
- `frameId` : 2 bytes, little-endian
- `chunkIndex` : 1 byte
- `totalChunks` : 1 byte
- `payloadLen` : 1 byte
- `payload` : up to `80` bytes

Rules:

- `chunkIndex = 0` starts a new frame assembly.
- Last frame may carry less than `80` bytes.
- Total message is complete only when all chunks arrive in order and expected length matches.

## 8. ACK Model

Two ACK layers are required.

### LoRa Frame ACK

- Receiver gateway sends ACK for every LoRa frame.
- Sender gateway retries on timeout.
- This handles lossy LoRa transport.

### Message Completion ACK

- After full message assembly and validation, receiver side sends final done/delivery ACK.
- Sender marks the message delivered only after final completion ACK.

## 9. Message Families

Use a single binary transport system with different packet types.

### Text

For small text:

- one packet can be enough

Recommended text header:

- `messageId`
- `timestamp`
- `textCrc`

Payload:

- UTF-8 text bytes

### Image

Recommended packet sequence:

- `IMAGE_START`
- `IMAGE_CHUNK`
- `IMAGE_DONE`
- `IMAGE_CNAK` when a chunk is missing/corrupt
- `IMAGE_DACK` when fully stored

`IMAGE_START` header:

- `messageId`
- `totalChunks`
- `fileExtension`
- optional `timestamp`

`IMAGE_CHUNK` header:

- `messageId`
- `seq`
- `totalChunks`
- `chunkCrc`

`IMAGE_CHUNK` payload:

- raw compressed image bytes

`IMAGE_DONE` header:

- `messageId`
- `totalChunks`
- `fullImageCrc`

### Audio

Recommended packet sequence:

- `AUDIO_START`
- `AUDIO_CHUNK`
- `AUDIO_DONE`
- `AUDIO_CNAK`
- `AUDIO_DACK`

`AUDIO_START` header:

- `messageId`
- `totalChunks`

`AUDIO_CHUNK` header:

- `messageId`
- `seq`
- `totalChunks`
- `chunkCrc`

`AUDIO_CHUNK` payload:

- compressed audio bytes

`AUDIO_DONE` header:

- `messageId`
- `totalChunks`
- `fullAudioCrc`

## 10. Metadata Optimization

To reduce overhead:

- put repeated metadata in first packet or start packet
- keep middle packets small
- include final whole-message CRC only in done packet

Recommended division:

- first packet:
  `messageId`, `messageType`, `timestamp`, `totalChunks`, extra metadata
- middle packet:
  `messageId`, `seq`, `chunkCrc`
- last or done packet:
  `messageId`, `totalChunks`, `finalCrc`

## 11. Encryption Layers

### Gateway <-> Server

Used for:

- discover
- presence
- key fetch
- relay request
- register ack and other control responses

Method:

- derive transport key from gateway keypair and server public/private key pair

### Gateway <-> Gateway

Used for:

- secure text/image/audio frames
- per-frame delivery ACK

Method:

- sender gateway derives peer session key from selected peer public key
- receiver gateway derives the same key from sender public key context

## 12. Server Responsibilities

The server should:

- store `(nodeId, name, publicKey)`
- track presence
- return peer lists
- return signed peer public keys
- relay encrypted peer packets without interpreting message contents

The server should not be the chat endpoint.

## 13. Phone Storage Rules

Phone stores a message in database only when:

1. all chunks are received
2. final CRC passes
3. message is marked complete

Store fields:

- `id`
- `peerId`
- `timestamp`
- `fromUser`
- `mediaType`
- `text` or local file path
- delivery status

## 14. Chat UI Rules

- Messages are filtered by `peerId`.
- Local user messages are shown on the right.
- Remote peer messages are shown on the left.
- Receiver phone can display messages from its connected gateway even when sender phone is offline.

## 15. Recommended Packet Types

Suggested logical packet families:

- gateway control:
  `GW_REGISTER_REQ`, `GW_REGISTER_ACK`, `GW_DISCOVER_REQ`, `GW_PEER_LIST`, `GW_SELECT_PEER`, `GW_FETCH_PEER_KEY`, `GW_PEER_READY`, `GW_ERROR`, `GW_QUEUE_STATUS`
- text:
  `TEXT_MSG`, `TEXT_ACK`, `TEXT_CNAK`, `TEXT_DACK`
- image:
  `IMAGE_START`, `IMAGE_CHUNK`, `IMAGE_DONE`, `IMAGE_CACK`, `IMAGE_CNAK`, `IMAGE_DACK`
- audio:
  `AUDIO_START`, `AUDIO_CHUNK`, `AUDIO_DONE`, `AUDIO_CACK`, `AUDIO_CNAK`, `AUDIO_DACK`

## 16. Final Agreed Architecture

This project should follow these final rules:

- raw binary over BLE
- no phone-to-gateway BLE encryption
- encryption only at Heltec layer
- binary transport packets with CRC
- 240-byte BLE chunking
- 80-byte LoRa framing
- per-frame ACK on LoRa
- final message completion ACK
- server-mediated relay for peer traffic
- server-signed public key distribution
- DB insert only after full validation
