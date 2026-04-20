# Realtime LoRa Media App Flowchart

This file summarizes the flow across:

- `lib/main.dart`
- `lib/realtimeaudio_main.dart`
- `lib/database_service.dart`
- `lib/tx.ino`
- `lib/rx.ino`

## Overall System Flow

```mermaid
flowchart TD
    A[App starts] --> B[Initialize Flutter bindings]
    B --> C[Initialize local notifications]
    C --> D[Run MyApp]
    D --> E[Open ScanScreen]
    E --> F[Request Bluetooth, location, camera, mic, notification permissions]
    F --> G{User taps Search Devices?}
    G -->|Yes| H[Check Bluetooth state]
    H --> I{Bluetooth ON?}
    I -->|No| J[Prompt user to enable Bluetooth]
    I -->|Yes| K[Check location service]
    K --> L{Location enabled?}
    L -->|No| M[Prompt user to enable location]
    L -->|Yes| N[Start BLE scan for Heltec devices]
    N --> O[Show scan results]
    O --> P[User selects device]
    P --> Q[Open ChatScreen]

    Q --> R[Connect to BLE device]
    R --> S[Request MTU and discover services]
    S --> T[Find target characteristic]
    T --> U[Enable notifications]
    U --> V[Ready to transmit]

    V --> W{User action}
    W -->|Send text| X[Create message ID and timestamp]
    W -->|Pick image| Y[Compress image and prepare chunks]
    W -->|Realtime audio| Z[Open realtime audio page / start streaming]

    X --> AA[Store outgoing message in SQLite as pending]
    AA --> AB[Build transport packet]
    Y --> AB
    Z --> AC[Build BLE audio packets]

    AB --> AD[Write packet to BLE characteristic]
    AC --> AD
    AD --> AE[Heltec board receives over BLE]

    AE --> AF{Payload type?}
    AF -->|Transport packet| AG[Assemble complete packet if needed]
    AF -->|Realtime audio| AH[Handle START / DATA / STOP audio packets]

    AG --> AI[Fragment transport packet into LoRa frames]
    AI --> AJ[Queue LoRa TX packets]

    AH --> AK[Buffer PCM audio]
    AK --> AL[Codec2 encode]
    AL --> AM[Queue LoRa audio packets]

    AJ --> AN[Transmit over LoRa]
    AM --> AN
    AN --> AO[Remote Heltec receives LoRa]

    AO --> AP{LoRa packet type?}
    AP -->|Transport frame| AQ[Reassemble transport packet]
    AP -->|Audio packet| AR[Decode Codec2 audio]

    AQ --> AS[Notify Flutter app over BLE]
    AR --> AT[Stream decoded PCM over BLE notify]
    AS --> AU[Flutter parses packet]
    AT --> AV[Flutter buffers and plays audio]

    AU --> AW{Content type?}
    AW -->|Text| AX[Update DB and show chat bubble]
    AW -->|Image| AY[Reassemble image, save file, show image bubble]
    AW -->|Audio file or session events| AZ[Update UI state / save media]

    AX --> BA[Show local notification if needed]
    AY --> BA
    AZ --> BA
```

## Chat and Media Flow

```mermaid
flowchart TD
    A1[ChatScreen opens] --> A2[Load messages from DatabaseService]
    A2 --> A3[Render bubbles for text, image, and audio]

    A3 --> A4{User sends what?}
    A4 -->|Text| A5[Validate transfer allowed and input non-empty]
    A4 -->|Image| A6[Pick image from device]
    A4 -->|Audio clip / realtime action| A7[Open audio flow]

    A5 --> A8[Insert pending text row in SQLite]
    A6 --> A9[Resize and compress image]
    A9 --> A10[Split image into chunks]
    A10 --> A11[Send image START]
    A11 --> A12[Send IMAGE CHUNK packets]
    A12 --> A13[Send IMAGE DONE]
    A13 --> A14[Handle ACK / missing batch / resend if needed]

    A8 --> A15{Fits single packet?}
    A15 -->|Yes| A16[Send single text packet]
    A15 -->|No| A17[Send TEXT START]
    A17 --> A18[Send TEXT CHUNK packets]
    A18 --> A19[Send TEXT DONE]
    A19 --> A20[Handle ACK / missing batch / resend if needed]

    A16 --> A21[Update message status]
    A20 --> A21
    A14 --> A22[Save outgoing image path and refresh chat]
    A21 --> A23[Reload messages from DB]
    A22 --> A23
```

## Realtime Audio Flow

```mermaid
flowchart TD
    R1[User taps mic / PTT] --> R2[Check BLE connected and mic permission]
    R2 --> R3[Start recorder stream]
    R3 --> R4[Send BLE AUDIO START]
    R4 --> R5[Collect PCM chunks]
    R5 --> R6[Send BLE AUDIO DATA packets]
    R6 --> R7[Heltec receives audio over BLE]
    R7 --> R8[Push raw audio into ring buffer]
    R8 --> R9[Codec2 encode frames]
    R9 --> R10[Queue LoRa audio packets]
    R10 --> R11[Transmit over LoRa]
    R11 --> R12[Remote Heltec receives audio packets]
    R12 --> R13[Codec2 decode to PCM]
    R13 --> R14[Push decoded PCM into playback buffer]
    R14 --> R15[Notify phone with BLE audio packets]
    R15 --> R16[Flutter app buffers audio with jitter prebuffer]
    R16 --> R17[Play audio through speaker]

    R17 --> R18{Stream stops or idle timeout?}
    R18 -->|Yes| R19[Send BLE / LoRa STOP]
    R19 --> R20[Finalize received WAV clip]
    R20 --> R21[Show saved clip in receiver list]
```

## Database Flow

```mermaid
flowchart LR
    D1[DatabaseService init] --> D2[Open messages.db]
    D2 --> D3[Create / upgrade tables]
    D3 --> D4[(messages)]
    D3 --> D5[(identity)]
    D3 --> D6[(contacts)]

    M1[Outgoing or incoming message] --> M2[insertMessage]
    M2 --> D4
    M3[Delivery state changes] --> M4[updateStatus / markAttempt / incrementRetry]
    M4 --> D4
    M5[Chat screen refresh] --> M6[getAllMessages or getMessagesForConversation]
    D4 --> M6
```
