# PowerPoint Flowcharts

These flowcharts are simplified for presentation slides and are easier to explain than the detailed engineering flow.

## 1. Project Overview Flowchart

```mermaid
flowchart LR
    A[User Opens Flutter App] --> B[Scan Nearby Heltec Devices]
    B --> C[Connect to BLE Device]
    C --> D{Choose Communication Mode}

    D --> E[Send Text]
    D --> F[Send Image]
    D --> G[Send Realtime Audio]

    E --> H[Phone Builds Packet]
    F --> H
    G --> I[Phone Captures Voice]

    H --> J[BLE Transfer to Heltec]
    I --> J

    J --> K[Heltec Relays Data Over LoRa]
    K --> L[Remote Heltec Receives]
    L --> M[Forward Data to Remote Phone via BLE]

    M --> N{Received Content}
    N --> O[Show Text in Chat]
    N --> P[Show Image in Chat]
    N --> Q[Play or Save Audio]
```

## 2. Text Message Flowchart

```mermaid
flowchart TD
    A[User Types Message] --> B[App Creates Message ID and Timestamp]
    B --> C{Small Message?}

    C -->|Yes| D[Send as Single Text Packet]
    C -->|No| E[Split Text into Chunks]

    E --> F[Send Text Start Packet]
    F --> G[Send Text Chunks]
    G --> H[Send Text Done Packet]

    D --> I[BLE Transfer to Heltec]
    H --> I

    I --> J[Heltec Fragments Data for LoRa]
    J --> K[LoRa Transmission]
    K --> L[Remote Heltec Reassembles Data]
    L --> M[Remote Phone Receives Text]
    M --> N[Store in Database]
    N --> O[Display in Chat Screen]
```

## 3. Image Transfer Flowchart

```mermaid
flowchart TD
    A[User Selects Image] --> B[App Compresses and Resizes Image]
    B --> C[Split Image into Chunks]
    C --> D[Send Image Start Packet]
    D --> E[Send Image Chunks]
    E --> F[Send Image Done Packet]

    F --> G[BLE Transfer to Heltec]
    G --> H[Heltec Sends Chunks Over LoRa]
    H --> I[Remote Heltec Receives]
    I --> J[Remote Phone Reassembles Image]
    J --> K{Any Chunks Missing?}

    K -->|Yes| L[Request Missing Sequence Numbers]
    L --> M[Resend Only Missing Chunks]
    M --> J

    K -->|No| N[Verify Full Image CRC]
    N --> O[Save Image Locally]
    O --> P[Display Image in Chat]
```

## 4. Realtime Audio Flowchart

```mermaid
flowchart TD
    A[User Presses Mic / PTT] --> B[Check BLE Connection and Permissions]
    B --> C[Capture PCM Audio from Microphone]
    C --> D[Send Audio to Heltec via BLE]
    D --> E[Heltec Compresses Audio with Codec2]
    E --> F[Transmit Audio Over LoRa]
    F --> G[Remote Heltec Receives Audio]
    G --> H[Decode Audio Back to PCM]
    H --> I[Send Audio to Remote Phone via BLE]
    I --> J[Remote Phone Buffers Audio]
    J --> K[Play Audio Through Speaker]
    K --> L[Optionally Save Received WAV Clip]
```

## 5. Reliability Flowchart

```mermaid
flowchart TD
    A[Start Transfer] --> B[Send Packet / Chunk]
    B --> C[Receiver Checks CRC and Sequence]
    C --> D{Packet Correct?}

    D -->|Yes| E[Store Chunk]
    E --> F{All Chunks Received?}

    F -->|No| G[Request Missing Sequence Numbers]
    G --> H[Sender Resends Missing Chunks]
    H --> C

    F -->|Yes| I[Rebuild Full Message or Image]
    I --> J[Verify Final CRC]
    J --> K[Save and Display Content]

    D -->|No| G
```

## Suggested Slide Order

```text
Slide 1: Project Overview Flowchart
Slide 2: Text Message Flowchart
Slide 3: Image Transfer Flowchart
Slide 4: Realtime Audio Flowchart
Slide 5: Reliability / Missing Sequence Handling
```

## Short Presenter Summary

```text
This project is a Flutter-based communication system that uses BLE to connect a phone to a Heltec LoRa device.
The Heltec board works as a gateway and relays text, images, and realtime audio over LoRa to another device.
At the receiving side, data is reconstructed and shown in the app as chat messages, images, or audio.
To improve reliability, the system uses chunking, CRC verification, acknowledgments, and missing-sequence recovery.
```
