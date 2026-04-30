# Setup And Run Guide

This guide explains how to initialize and run this project after cloning it from GitHub.

## Requirements

- Flutter SDK installed and added to PATH
- Android Studio or VS Code with Flutter/Dart plugins
- Android SDK installed
- A physical Android phone with Bluetooth enabled
- USB cable for Android debugging
- Arduino IDE or PlatformIO for flashing the Heltec boards
- Two compatible Heltec ESP32 LoRa boards

The app uses Bluetooth, location, camera, microphone, notifications, native Android code, and an `arm64-v8a` Codec2 library. A real Android phone is recommended. The Android emulator usually cannot test the BLE/LoRa flow properly.

## 1. Clone The Repository

```bash
git clone <your-repository-url>
cd realtime_lora_media_app
```

## 2. Check Flutter

Run:

```bash
flutter doctor
```

Fix any Android toolchain issues shown by `flutter doctor` before running the app.

## 3. Install Flutter Packages

Run:

```bash
flutter pub get
```

This downloads the Dart and Flutter packages listed in `pubspec.yaml`.

## 4. Prepare Android

Connect your Android phone by USB, then enable:

- Developer options
- USB debugging
- Bluetooth
- Location services

Check that Flutter can see the phone:

```bash
flutter devices
```

If the phone does not appear, reconnect USB, accept the debugging prompt on the phone, and run `flutter devices` again.

## 5. Flash The Heltec Boards

The board sketches are:

- `lib/heltec1.ino` for the first Heltec board
- `lib/heltec2.ino` for the second Heltec board

Open each sketch in Arduino IDE or PlatformIO and install the required board support/libraries used by the sketches:

- ESP32 board support
- RadioLib
- ESP32 BLE libraries
- RingBuf
- Codec2 library/header support

Both sketches currently use:

- BLE service UUID: `12345678-1234-1234-1234-1234567890ab`
- BLE characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456`
- LoRa frequency: `866.0 MHz`
- First board BLE name: `Heltec_1`
- Second board BLE name: `Heltec_2`

Make sure the LoRa frequency is legal for your region and matches on both boards.

## 6. Run The App

For development:

```bash
flutter run
```

For a release APK:

```bash
flutter build apk --release
```

The generated APK will be inside:

```text
build/app/outputs/flutter-apk/
```

## 7. Use The App

1. Power on the Heltec boards.
2. Open the app on the Android phone.
3. Allow Bluetooth, location, camera, microphone, and notification permissions.
4. Tap `Search Devices`.
5. Select a BLE device named `Heltec_1`, `Heltec_2`, or another Heltec gateway name.
6. Wait until the chat screen shows `Ready to Transmit`.
7. Send text, images, or audio from the chat screen.

## Troubleshooting

If no device appears while scanning:

- Turn on phone Bluetooth.
- Turn on phone location services.
- Confirm app permissions are allowed in Android settings.
- Confirm the Heltec board is powered and advertising over BLE.
- Confirm the device name contains `Heltec`, because the app scan filters for that keyword.

If the app builds but does not connect:

- Keep the phone close to the Heltec board.
- Restart Bluetooth on the phone.
- Restart the Heltec board.
- Check the UUID values in the app and sketches match.

If Android build fails:

- Run `flutter clean`
- Run `flutter pub get`
- Run `flutter doctor`
- Make sure Android Studio installed the Android SDK, CMake, NDK, and platform tools.

If LoRa messages do not arrive:

- Confirm both boards use the same LoRa frequency, bandwidth, spreading factor, coding rate, sync word, and preamble.
- Confirm antennas are connected.
- Keep boards close while testing first.
- Watch the serial monitor logs from both boards.

## Important Files

- `lib/main.dart`: Flutter app UI, BLE scan/connect logic, and message handling
- `lib/realtimeaudio_main.dart`: realtime audio screen/logic
- `lib/database_service.dart`: local message storage
- `lib/heltec1.ino`: first Heltec gateway sketch
- `lib/heltec2.ino`: second Heltec gateway sketch
- `android/app/src/main/cpp/`: native Android Codec2 bridge
- `PROTOCOL.md`: transport and protocol design notes
