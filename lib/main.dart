import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'database_service.dart';
import 'dart:io';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:sound_stream/sound_stream.dart';
import 'realtimeaudio_main.dart' as realtime_audio;
enum MediaMode {
  idle,
  recording,
  image,
}

enum _TransferSessionType {
  text,
  image,
  realtimeAudio,
}

class _TransportPacket {
  const _TransportPacket({
    required this.type,
    required this.header,
    required this.payload,
  });

  final int type;
  final Uint8List header;
  final Uint8List payload;
}

class _PacketReader {
  _PacketReader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  int readUint8() => bytes[_offset++];

  int readUint16() {
    final value = bytes[_offset] | (bytes[_offset + 1] << 8);
    _offset += 2;
    return value;
  }

  int readUint32() {
    final value = bytes[_offset] |
        (bytes[_offset + 1] << 8) |
        (bytes[_offset + 2] << 16) |
        (bytes[_offset + 3] << 24);
    _offset += 4;
    return value & 0xFFFFFFFF;
  }

  int readUint64() {
    var value = 0;
    for (int i = 0; i < 8; i++) {
      value |= bytes[_offset + i] << (8 * i);
    }
    _offset += 8;
    return value;
  }

  String readString8() {
    final length = readUint8();
    final out = utf8.decode(bytes.sublist(_offset, _offset + length));
    _offset += length;
    return out;
  }
}

enum _BleRealtimePacketType {
  start(0x01),
  audio(0x02),
  stop(0x03);

  const _BleRealtimePacketType(this.code);
  final int code;
}

const int _bleRealtimeMagic = 0xA5;
const int _bleRealtimeHeaderBytes = 8;
const int _bleRealtimePayloadBytes = 200;
const int _bleRealtimeHeaderSizeField = 8;
const int _bleRealtimeVersion = 1;
const int _realtimePlaybackSampleRate = 8000;
const int _realtimePlaybackChunkBytes = 200;
const int _realtimeJitterPrebufferBytes = 960;
const int _realtimePlaybackBufferMaxBytes = 4000;
const int _realtimePlaybackTickMs = 13;
const double _realtimeReceiverPlaybackGain = 3.0;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Enhanced logging to help debug radio timing
  FlutterBluePlus.setLogLevel(LogLevel.info);
  NotificationService.instance.init();
  runApp(const MyApp());
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings);

    const androidChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Incoming messages',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'Incoming messages',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

// --- SCAN SCREEN ---
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _isScanning = false;
  late StreamSubscription<bool> _scanSubscription;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _scanSubscription = FlutterBluePlus.isScanning.listen((s) {
      if (mounted) setState(() => _isScanning = s);
    });
  }

  @override
  void dispose() {
    _scanSubscription.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ].request();
  }

  void _startScan() async {
    try {
      final btState = await FlutterBluePlus.adapterState.first;
      if (btState != BluetoothAdapterState.on) {
        await _promptEnableBluetooth();
        return;
      }

      final locationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locationEnabled) {
        await _promptEnableLocation();
        return;
      }

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withKeywords: ["Heltec"], // Filter specifically for your boards
      );
    } catch (e) {
      debugPrint("Scan Error: $e");
    }
  }

  Future<void> _promptEnableBluetooth() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Bluetooth is off"),
        content:
            const Text("Please enable Bluetooth to scan for nearby devices."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await FlutterBluePlus.turnOn();
              } catch (_) {
                // If user rejects or device can't turn on programmatically.
              }
            },
            child: const Text("Turn on"),
          ),
        ],
      ),
    );
  }

  Future<void> _promptEnableLocation() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Location is off"),
        content: const Text(
            "Please enable Location services to scan for nearby devices."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await Geolocator.openLocationSettings();
            },
            child: const Text("Open settings"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("LoRa-BLE Gateway")),
      body: Column(
        children: [
          LinearProgressIndicator(value: _isScanning ? null : 0),
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              builder: (context, snapshot) {
                final results = snapshot.data ?? [];
                return ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final r = results[index];
                    return ListTile(
                      leading: const Icon(Icons.router),
                      title: Text(r.device.platformName.isEmpty ? "Unknown" : r.device.platformName),
                      subtitle: Text(r.device.remoteId.str),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ChatScreen(device: r.device)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        label: Text(_isScanning ? "Scanning..." : "Search Devices"),
        icon: const Icon(Icons.bluetooth_searching),
      ),
    );
  }
}

// --- CHAT SCREEN ---
class ChatScreen extends StatefulWidget {
  final BluetoothDevice device;
  const ChatScreen({required this.device, super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  bool _chunkInFlight = false;
  final Set<String> _earlyChunkAcks = {};
 Future<void> _transportCooldown() async {
  _log("transport cooldown");

  // allow BLE + LoRa buffers to flush
  await Future.delayed(
      const Duration(milliseconds: 280));
}
int _lastImageActivityMs = 0;
void _markImageActivity(String reason) {
  _lastImageActivityMs = DateTime.now().millisecondsSinceEpoch;
  _log("image activity reason=$reason at=$_lastImageActivityMs");
}
Future<void> _audioStabilizationCooldown() async {
  if (_lastImageActivityMs == 0) return;
  const int minGapMs = 900;
  final now = DateTime.now().millisecondsSinceEpoch;
  final elapsed = now - _lastImageActivityMs;
  if (elapsed >= minGapMs) return;

  final waitMs = minGapMs - elapsed;
  _log("audio settle wait=${waitMs}ms after image activity");
  await Future.delayed(Duration(milliseconds: waitMs));
}
Uint8List _silentPcmFrame() {
  // 20ms @ 8kHz mono 16bit
  // 8000 samples/sec → 160 samples / 20ms
  // 160 samples × 2 bytes
  return Uint8List(320);
}
Uint8List _enhanceRecordedTxPcm(Uint8List pcmBytes) {
  if (pcmBytes.length < 2 || pcmBytes.length.isOdd) return pcmBytes;

  final inData = ByteData.sublistView(pcmBytes);
  final outBytes = Uint8List(pcmBytes.length);
  final outData = ByteData.sublistView(outBytes);
  final sampleCount = pcmBytes.length ~/ 2;

  double sumAbs = 0.0;
  double peak = 0.0;

  for (int i = 0; i < sampleCount; i++) {
    final v = inData.getInt16(i * 2, Endian.little).abs().toDouble();
    sumAbs += v;
    if (v > peak) peak = v;
  }

  final avgAbs = sampleCount > 0 ? (sumAbs / sampleCount) : 0.0;
  if (avgAbs < 70.0) return pcmBytes;

  final peakHeadroom = peak > 0 ? (28000.0 / peak) : 1.0;
  double gain = 6800.0 / (avgAbs + 1.0);
  gain = gain.clamp(1.0, 1.55);
  gain = gain.clamp(0.0, peakHeadroom);

  for (int i = 0; i < sampleCount; i++) {
    double v = inData.getInt16(i * 2, Endian.little).toDouble() * gain;

    final av = v.abs();
    if (av > 23500.0) {
      final compressed = 23500.0 + ((av - 23500.0) / 6.0);
      v = v.isNegative ? -compressed : compressed;
    }

    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    outData.setInt16(i * 2, v.round(), Endian.little);
  }

  return outBytes;
}
Uint8List _polishRecordedRxPcm(Uint8List pcmBytes) {
  if (pcmBytes.length < 2 || pcmBytes.length.isOdd) return pcmBytes;

  final inData = ByteData.sublistView(pcmBytes);
  final outBytes = Uint8List(pcmBytes.length);
  final outData = ByteData.sublistView(outBytes);
  final sampleCount = pcmBytes.length ~/ 2;

  for (int i = 0; i < sampleCount; i++) {
    double v = inData.getInt16(i * 2, Endian.little).toDouble() * 1.12;

    final av = v.abs();
    if (av > 24000.0) {
      final limited = 24000.0 + ((av - 24000.0) / 6.0);
      v = v.isNegative ? -limited : limited;
    }

    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    outData.setInt16(i * 2, v.round(), Endian.little);
  }

  return outBytes;
}

MediaMode _mediaMode = MediaMode.idle;
bool _canStart(MediaMode mode) {
  return _mediaMode == MediaMode.idle ||
         _mediaMode == mode;
}
  // ===============================
  // WhatsApp-like image compression
  // ===============================
  static const int _maxDimension = 960;
  static const int _targetSizeKb =15;
  static const int _minQuality = 35;
  static const int _maxQuality = 75;
  static const int _minQuantizer = 0;
  static const int _maxQuantizer = 63;
  static const String _nativeImageFormat = "WEBP";
  static const String _logTag = "LORA_CHAT";

  static const int _maxAllowedPackets = 120;
  static const int _loraPayloadBytes = 80; // conservative chunk size for noisy links
  static const int _imageChunkSizeBytes = 100;
  static const int _transportMagicLo = 0xB5;
  static const int _transportMagicHi = 0x62;
  static const int _transportVersion = 1;
  static const int _transportPrefixBytes = 11;
  static const int _packetTextMsg = 1;
  static const int _packetTextAck = 2;
  static const int _packetTextCnak = 3;
  static const int _packetImageStart = 4;
  static const int _packetImageChunk = 5;
  static const int _packetImageDone = 6;
  static const int _packetImageCack = 7;
  static const int _packetImageCnak = 8;
  static const int _packetImageDack = 9;
  static const int _packetAudioChunk = 10;
  static const int _packetAudioDone = 11;
  static const int _packetAudioCack = 12;
  static const int _packetAudioCnak = 13;
  static const int _packetAudioDack = 14;
  static const int _packetRtStart = 15;
  static const int _packetRtAudio = 16;
  static const int _packetRtStop = 17;
  static const int _packetTextStart = 18;
  static const int _packetTextStop = 19;
  static const int _packetImageStartAck = 20;
  static const int _packetImageMissingBatch = 21;
  static const int _packetTextChunk = 22;
  static const int _packetTextDone = 23;
  static const int _packetTextStartAck = 24;
  static const int _packetTextMissingBatch = 25;
  static const int _packetTextDack = 26;
  static const int _imageMissingBatchSize = 12;
  static const int _imageMissingRetryLimit = 6;
  static const int _imageMissingRetryCooldownMs = 1200;
  static const int _textChunkSizeBytes = 60;
  static const int _textSinglePacketThresholdBytes = 160;
  static const int _textMissingBatchSize = 24;
  static const int _textMissingRetryLimit = 6;
  static const int _textMissingRetryCooldownMs = 700;
  
  void _log(String message) {
    debugPrint("[$_logTag] $message");
  }
  String _notificationTitle() {
    final name = widget.device.platformName.trim();
    return name.isEmpty ? "LoRa Chat" : name;
  }
  Future<void> _notifyIncoming(String body) async {
    await NotificationService.instance.showMessage(
      title: _notificationTitle(),
      body: body,
    );
  }
  int _crc32(List<int> bytes) {
    const int polynomial = 0xEDB88320;
    int crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc ^= (b & 0xFF);
      for (int i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ polynomial;
        } else {
          crc = crc >> 1;
        }
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
  int _crc32OfString(String value) {
    return _crc32(utf8.encode(value));
  }
  Uint8List _u16Bytes(int value) =>
      Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);
  Uint8List _u32Bytes(int value) => Uint8List.fromList([
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ]);
  Uint8List _u64Bytes(int value) {
    final out = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      out[i] = (value >> (8 * i)) & 0xFF;
    }
    return out;
  }

  Uint8List _string8(String value) {
    final bytes = utf8.encode(value);
    if (bytes.length > 255) {
      throw ArgumentError("string too long for transport header");
    }
    return Uint8List.fromList([bytes.length, ...bytes]);
  }

  Uint8List _buildTransportPacket({
    required int type,
    Uint8List? header,
    Uint8List? payload,
  }) {
    final headerBytes = header ?? Uint8List(0);
    final payloadBytes = payload ?? Uint8List(0);
    if (headerBytes.length > 255) {
      throw ArgumentError("transport header too large");
    }
    if (payloadBytes.length > 0xFFFF) {
      throw ArgumentError("transport payload too large");
    }

    final crcInput = BytesBuilder(copy: false)
      ..add([
        _transportVersion,
        type,
        headerBytes.length,
        payloadBytes.length & 0xFF,
        (payloadBytes.length >> 8) & 0xFF,
      ])
      ..add(headerBytes)
      ..add(payloadBytes);
    final crc = _crc32(crcInput.takeBytes());

    return Uint8List.fromList([
      _transportMagicLo,
      _transportMagicHi,
      _transportVersion,
      type,
      headerBytes.length,
      payloadBytes.length & 0xFF,
      (payloadBytes.length >> 8) & 0xFF,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 24) & 0xFF,
      ...headerBytes,
      ...payloadBytes,
    ]);
  }

  _TransportPacket? _decodeTransportPacket(Uint8List packetBytes) {
    if (packetBytes.length < _transportPrefixBytes) return null;
    if (packetBytes[0] != _transportMagicLo || packetBytes[1] != _transportMagicHi) {
      return null;
    }

    final version = packetBytes[2];
    final type = packetBytes[3];
    final headerLen = packetBytes[4];
    final payloadLen = packetBytes[5] | (packetBytes[6] << 8);
    final expectedTotal = _transportPrefixBytes + headerLen + payloadLen;
    if (version != _transportVersion || packetBytes.length != expectedTotal) {
      return null;
    }

    final expectedCrc = packetBytes[7] |
        (packetBytes[8] << 8) |
        (packetBytes[9] << 16) |
        (packetBytes[10] << 24);
    final crcInput = BytesBuilder(copy: false)
      ..add(packetBytes.sublist(2, 7))
      ..add(packetBytes.sublist(_transportPrefixBytes, _transportPrefixBytes + headerLen))
      ..add(packetBytes.sublist(_transportPrefixBytes + headerLen, expectedTotal));
    final actualCrc = _crc32(crcInput.takeBytes());
    if (actualCrc != expectedCrc) {
      _log("transport crc mismatch type=$type expected=$expectedCrc actual=$actualCrc");
      return null;
    }

    final headerStart = _transportPrefixBytes;
    final payloadStart = headerStart + headerLen;
    return _TransportPacket(
      type: type,
      header: Uint8List.sublistView(packetBytes, headerStart, payloadStart),
      payload: Uint8List.sublistView(packetBytes, payloadStart, expectedTotal),
    );
  }

  Future<void> _writeTransportPacket(Uint8List packet) async {
    _writeQueue = _writeQueue.then((_) async {
      if (targetChar == null) {
        _log("writeTransportPacket skipped: targetChar null");
        return;
      }
      await targetChar!.write(packet, withoutResponse: false);
      _log("tx packet bytes=${packet.length}");
    }).catchError((e) {
      _log("writeTransportPacket error: $e");
    });
    await _writeQueue;
  }

  Future<void> _writeBleRealtimePacket(Uint8List packet) async {
    _writeQueue = _writeQueue.then((_) async {
      if (targetChar == null) {
        _log("writeBleRealtimePacket skipped: targetChar null");
        return;
      }
      await targetChar!.write(packet, withoutResponse: false);
    }).catchError((e) {
      _log("writeBleRealtimePacket error: $e");
    });
    await _writeQueue;
  }

  Uint8List _buildBleRealtimeAudioPacket({
    required int sequence,
    required Uint8List payload,
    required bool isFinalChunk,
  }) {
    return Uint8List.fromList([
      _bleRealtimeMagic,
      _BleRealtimePacketType.audio.code,
      sequence & 0xFF,
      (sequence >> 8) & 0xFF,
      payload.length,
      _bleRealtimeHeaderSizeField,
      _bleRealtimeVersion,
      isFinalChunk ? 0x01 : 0x00,
      ...payload,
    ]);
  }

  Uint8List _buildBleRealtimeControlPacket(_BleRealtimePacketType type) {
    return Uint8List.fromList([
      _bleRealtimeMagic,
      type.code,
      0x00,
      0x00,
      0x00,
      _bleRealtimeHeaderSizeField,
      _bleRealtimeVersion,
      0x00,
    ]);
  }
  void _clearAckStateForId(String id) {
    _earlyChunkAcks.removeWhere((k) => k.startsWith("$id:"));
    _chunkAckWaiters.removeWhere((k, _) => k.startsWith("$id:"));
  }
  Future<void> _sendTextWithCrc({
    required String id,
    required int timestamp,
    required String text,
  }) async {
    final crc = _crc32OfString(text);
    _textTxCache[id] = _TextTxCacheEntry(
      timestamp: timestamp,
      text: text,
      crc: crc,
    );
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u64Bytes(timestamp))
      ..add(_u32Bytes(crc));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetTextMsg,
        header: header.takeBytes(),
        payload: Uint8List.fromList(utf8.encode(text)),
      ),
    );
  }
  int _estimatePacketCount(int byteLength) {
    if (byteLength <= 0) return 0;
    return (byteLength / _imageChunkSizeBytes).ceil();
  }
List<String> _getAllChatImages() {
  final images = <String>[];

  for (final msg in chatMessages) {
    if (msg is GestureDetector &&
        msg.child is MessageBubble) {

      final bubble =
          msg.child as MessageBubble;

      if (bubble.isImage) {
        images.add(bubble.content);
      }
    }
  }

  return images;
}
  void _clearPttBuffers(String reason) {
    _incomingPacketBuffer.clear();
    _log("ptt buffers cleared reason=$reason");
  }
  bool get _hasRemoteActiveTransfer => _remoteActiveTransferType != null;
  bool get _canStartTransfer {
    return isReady &&
        targetChar != null &&
        !_hasRemoteActiveTransfer &&
        !_isSendingMedia &&
        !_isSendingText &&
        !_isRecordingAudio &&
        _mediaMode == MediaMode.idle;
  }

  String _transferSessionLabel(_TransferSessionType type) {
    switch (type) {
      case _TransferSessionType.text:
        return "text";
      case _TransferSessionType.image:
        return "image";
      case _TransferSessionType.realtimeAudio:
        return "audio";
    }
  }

  void _setRemoteTransferLock(
    _TransferSessionType type,
    String id,
  ) {
    _remoteActiveTransferType = type;
    _remoteActiveTransferId = id;
    _log("remote transfer locked type=${_transferSessionLabel(type)} id=$id");
    if (mounted) {
      setState(() {});
    }
  }

  void _clearRemoteTransferLock({
    _TransferSessionType? type,
    String? id,
  }) {
    final matchesType = type == null || _remoteActiveTransferType == type;
    final matchesId = id == null || _remoteActiveTransferId == id;
    if (!matchesType || !matchesId) {
      return;
    }
    _log(
      "remote transfer unlocked "
      "type=${_remoteActiveTransferType != null ? _transferSessionLabel(_remoteActiveTransferType!) : "none"} "
      "id=${_remoteActiveTransferId ?? "none"}",
    );
    _remoteActiveTransferType = null;
    _remoteActiveTransferId = null;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startRealtimePlayback() async {
    if (!_realtimePlayerReady) {
      try {
        await _realtimePlayer.initialize(
          sampleRate: _realtimePlaybackSampleRate,
        );
        await _realtimePlayer.usePhoneSpeaker(true);
        await _realtimePlayer.start();
        _realtimePlayerReady = true;
      } catch (e) {
        _log("startRealtimePlayback init error: $e");
        return;
      }
    }
    _realtimePlaybackDrainTimer?.cancel();
    _realtimePlaybackDrainTimer = Timer.periodic(
      const Duration(milliseconds: _realtimePlaybackTickMs),
      (_) => unawaited(_drainRealtimePlaybackBuffer()),
    );
    if (_isPlayingRealtimeAudio) return;
    try {
      _isPlayingRealtimeAudio = true;
    } catch (e) {
      _log("startRealtimePlayback error: $e");
    }
  }

  Future<void> _playRealtimePcm(Uint8List pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    await _startRealtimePlayback();
    _realtimePlaybackBuffer.addAll(pcmBytes);
    while (_realtimePlaybackBuffer.length > _realtimePlaybackBufferMaxBytes) {
      _realtimePlaybackBuffer.removeFirst();
    }
  }

  Future<void> _stopRealtimePlayback() async {
    if (!_isPlayingRealtimeAudio) return;
    try {
      _realtimePlaybackDrainTimer?.cancel();
      _realtimePlaybackDrainTimer = null;
      if (_realtimePlayerReady) {
        if (_realtimePlaybackBuffer.isNotEmpty) {
          final tail = Uint8List.fromList(
            List<int>.generate(
              _realtimePlaybackBuffer.length,
              (_) => _realtimePlaybackBuffer.removeFirst(),
            ),
          );
          _realtimePlayer.audioStream.add(_applyRealtimePlaybackGain(tail));
        }
        await _realtimePlayer.stop();
        _realtimePlayerReady = false;
      }
      _realtimePlaybackBuffer.clear();
      _realtimePlaybackStarted = false;
    } catch (e) {
      _log("stopRealtimePlayback error: $e");
    } finally {
      _isPlayingRealtimeAudio = false;
    }
  }

  Future<void> _drainRealtimePlaybackBuffer() async {
    if (!_realtimePlayerReady) return;

    if (!_realtimePlaybackStarted) {
      if (_realtimePlaybackBuffer.length >= _realtimeJitterPrebufferBytes) {
        _realtimePlaybackStarted = true;
      } else {
        return;
      }
    }

    if (_realtimePlaybackBuffer.length < _realtimePlaybackChunkBytes) {
      return;
    }

    final chunk = Uint8List.fromList(
      List<int>.generate(
        _realtimePlaybackChunkBytes,
        (_) => _realtimePlaybackBuffer.removeFirst(),
      ),
    );
    _realtimePlayer.audioStream.add(_applyRealtimePlaybackGain(chunk));
  }

  Uint8List _applyRealtimePlaybackGain(Uint8List pcmBytes) {
    if (_realtimeReceiverPlaybackGain <= 1.0 || pcmBytes.length < 2) {
      return pcmBytes;
    }

    final samples = ByteData.sublistView(pcmBytes);
    for (var offset = 0; offset + 1 < pcmBytes.length; offset += 2) {
      final input = samples.getInt16(offset, Endian.little);
      final boosted = (input * _realtimeReceiverPlaybackGain).round();
      final clamped = boosted.clamp(-32768, 32767).toInt();
      samples.setInt16(offset, clamped, Endian.little);
    }
    return pcmBytes;
  }

  Future<void> _sendTextStartPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetTextStart, header: _string8(id)),
    );
  }

  Future<void> _sendTextStopPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetTextStop, header: _string8(id)),
    );
  }

  Future<void> _sendTextStartAckPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetTextStartAck, header: _string8(id)),
    );
  }

  Future<void> _sendTextChunkPacket({
    required String id,
    required int timestamp,
    required int seq,
    required int total,
    required Uint8List chunk,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u64Bytes(timestamp))
      ..add(_u16Bytes(seq))
      ..add(_u16Bytes(total))
      ..add(_u32Bytes(_crc32(chunk)));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetTextChunk,
        header: header.takeBytes(),
        payload: chunk,
      ),
    );
  }

  Future<void> _sendTextDonePacket({
    required String id,
    required int timestamp,
    required int total,
    required int textCrc,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u64Bytes(timestamp))
      ..add(_u16Bytes(total))
      ..add(_u32Bytes(textCrc));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetTextDone,
        header: header.takeBytes(),
      ),
    );
  }

  Future<void> _sendTextMissingBatchPacket(String id, List<int> missingSeqs) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(missingSeqs.length));
    for (final seq in missingSeqs) {
      header.add(_u16Bytes(seq));
    }
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetTextMissingBatch,
        header: header.takeBytes(),
      ),
    );
  }

  Future<void> _sendTextDackPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetTextDack, header: _string8(id)),
    );
  }

  Future<void> _sendRealtimeAudioStartPacket(String id) async {
    _activeRealtimeAudioId = id;
    await _writeBleRealtimePacket(
      _buildBleRealtimeControlPacket(_BleRealtimePacketType.start),
    );
  }

  Future<void> _sendRealtimeAudioPacket({
    required String id,
    required int seq,
    required Uint8List pcmChunk,
    bool isFinalChunk = false,
  }) async {
    await _writeBleRealtimePacket(
      _buildBleRealtimeAudioPacket(
        sequence: seq,
        payload: pcmChunk,
        isFinalChunk: isFinalChunk,
      ),
    );
  }

  Future<void> _sendRealtimeAudioStopPacket(String id) async {
    await _writeBleRealtimePacket(
      _buildBleRealtimeControlPacket(_BleRealtimePacketType.stop),
    );
  }

  Future<void> _sendTextSession({
    required String id,
    required int timestamp,
    required String text,
  }) async {
    final textBytes = Uint8List.fromList(utf8.encode(text));
    bool sentStart = false;
    if (textBytes.length <= _textSinglePacketThresholdBytes) {
      _isSendingText = true;
      if (mounted) {
        setState(() {});
      }
      try {
        final startAckCompleter = Completer<void>();
        _textStartAckWaiters[id] = startAckCompleter;
        await _sendTextStartPacket(id);
        sentStart = true;
        try {
          await startAckCompleter.future.timeout(const Duration(seconds: 4));
        } catch (_) {
          await DatabaseService.updateStatus(id, "failed");
          _loadMessagesFromDB();
          return;
        } finally {
          if (_textStartAckWaiters[id] == startAckCompleter) {
            _textStartAckWaiters.remove(id);
          }
        }
        await _sendTextWithCrc(id: id, timestamp: timestamp, text: text);
      } finally {
        if (sentStart) {
          await _sendTextStopPacket(id);
        }
        _isSendingText = false;
        if (mounted) {
          setState(() {});
        }
      }
      return;
    }

    _isSendingText = true;
    if (mounted) {
      setState(() {});
    }
    try {
      await _sendTextStartPacket(id);
      sentStart = true;
      final startAckCompleter = Completer<void>();
      _textStartAckWaiters[id] = startAckCompleter;
      try {
        await startAckCompleter.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        await DatabaseService.updateStatus(id, "failed");
        _loadMessagesFromDB();
        return;
      } finally {
        if (_textStartAckWaiters[id] == startAckCompleter) {
          _textStartAckWaiters.remove(id);
        }
      }

      final chunks = <Uint8List>[];
      for (int i = 0; i < textBytes.length; i += _textChunkSizeBytes) {
        final end = (i + _textChunkSizeBytes > textBytes.length)
            ? textBytes.length
            : i + _textChunkSizeBytes;
        chunks.add(Uint8List.fromList(textBytes.sublist(i, end)));
      }
      _txTextChunks[id] = chunks;

      for (int i = 0; i < chunks.length; i++) {
        await _sendTextChunkPacket(
          id: id,
          timestamp: timestamp,
          seq: i,
          total: chunks.length,
          chunk: chunks[i],
        );
        await Future.delayed(const Duration(milliseconds: 70));
      }

      final doneCompleter = Completer<void>();
      _doneAckWaiters[id] = doneCompleter;
      await _sendTextDonePacket(
        id: id,
        timestamp: timestamp,
        total: chunks.length,
        textCrc: _crc32(textBytes),
      );
      try {
        await doneCompleter.future.timeout(const Duration(seconds: 20));
        await DatabaseService.updateStatus(id, "delivered");
      } catch (_) {
        await DatabaseService.updateStatus(id, "failed");
      } finally {
        if (_doneAckWaiters[id] == doneCompleter) {
          _doneAckWaiters.remove(id);
        }
      }
      _loadMessagesFromDB();
    } finally {
      if (sentStart) {
        await _sendTextStopPacket(id);
      }
      _txTextChunks.remove(id);
      _isSendingText = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _flushRealtimeAudioFrame({bool allowPadding = false}) async {
    if (_activeRealtimeAudioId == null) return;
    const int pcmFrameBytes = _bleRealtimePayloadBytes;
    if (_realtimeAudioFrameBuffer.length < pcmFrameBytes && !allowPadding) {
      return;
    }
    if (_realtimeAudioFrameBuffer.isEmpty) return;

    final available = _realtimeAudioFrameBuffer.length > pcmFrameBytes
        ? pcmFrameBytes
        : _realtimeAudioFrameBuffer.length;
    final frameBytes = Uint8List(available);
    for (int i = 0; i < available; i++) {
      frameBytes[i] = _realtimeAudioFrameBuffer[i];
    }
    _realtimeAudioFrameBuffer.removeRange(0, available);

    await _sendRealtimeAudioPacket(
      id: _activeRealtimeAudioId!,
      seq: _realtimeAudioSeq++,
      pcmChunk: frameBytes,
      isFinalChunk: allowPadding && _realtimeAudioFrameBuffer.isEmpty,
    );
  }
  Future<void> _resetMedia() async {

  _log("RESET MEDIA");

  try {

    // stop recorder if running
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }

      } catch (_) {}

      await _realtimeAudioSubscription?.cancel();
      _realtimeAudioSubscription = null;
      _recordStopTimer?.cancel();
      await _stopRealtimePlayback();

      _isRecordingAudio = false;
      _activeRealtimeAudioId = null;
      _realtimeAudioSeq = 0;
      _realtimeAudioFrameBuffer.clear();
      _incomingRealtimeAudioPcmBuffer.clear();
      _incomingRealtimeAudioId = null;
      _incomingPacketBuffer.clear();

      _mediaMode = MediaMode.idle;
    }
  img.Image _resizeImage(img.Image source) {
    final w = source.width;
    final h = source.height;
    if (w <= _maxDimension && h <= _maxDimension) return source;

    int newW;
    int newH;
    if (w > h) {
      newW = _maxDimension;
      newH = (h * _maxDimension / w).round();
    } else {
      newH = _maxDimension;
      newW = (w * _maxDimension / h).round();
    }
    return img.copyResize(source, width: newW, height: newH);
  }
  img.Image _resizeImageToMax(img.Image source, int maxDimension) {
    final w = source.width;
    final h = source.height;
    if (w <= maxDimension && h <= maxDimension) return source;

    int newW;
    int newH;
    if (w > h) {
      newW = maxDimension;
      newH = (h * maxDimension / w).round();
    } else {
      newH = maxDimension;
      newW = (w * maxDimension / h).round();
    }
    return img.copyResize(source, width: newW, height: newH);
  }

  img.Image _denoiseImage(img.Image source) {
    // Lightweight denoise approximation (OpenCV NLM alternative).
    return img.gaussianBlur(source, radius: 1);
  }

  int _qualityToQuantizer(int quality) {
    final q = ((100 - quality) * 0.63).round();
    if (q < _minQuantizer) return _minQuantizer;
    if (q > _maxQuantizer) return _maxQuantizer;
    return q;
  }
  Future<void> _dispatchFrame(String line) async {

  try {

    if (line.startsWith("I|")) {
      await _handleImagePipePacket(
          line.substring(2));
      return;
    }

    if (line.startsWith("A|")) {
      await _handleAudioPipe(
          line.substring(2));
      return;
    }

    if (line.startsWith("T|")) {
      await _handleTextPipe(
          line.substring(2));
      return;
    }

    _log("unknown frame dropped SAFE: $line");

  } catch (e) {
    _log("dispatch error: $e");
  }
}
  Future<void> _dispatchTransportPacket(_TransportPacket packet) async {
    final reader = _PacketReader(packet.header);

    switch (packet.type) {
      case _packetTextMsg:
        final id = reader.readString8();
        final timestamp = reader.readUint64();
        final crc = reader.readUint32();
        final text = utf8.decode(packet.payload, allowMalformed: true);
        await _handleTextPipe("MSG|$id|$timestamp|$crc|$text");
        return;
      case _packetTextStart:
        final id = reader.readString8();
        _setRemoteTransferLock(
          _TransferSessionType.text,
          id,
        );
        await _sendTextStartAckPacket(id);
        return;
      case _packetTextStop:
        _clearRemoteTransferLock(
          type: _TransferSessionType.text,
          id: reader.readString8(),
        );
        return;
      case _packetTextStartAck:
        await _handleTextStartAckBinary(reader.readString8());
        return;
      case _packetTextAck:
        await _handleTextPipe("ACK|${reader.readString8()}");
        return;
      case _packetTextCnak:
        await _handleTextPipe("CNAK|${reader.readString8()}");
        return;
      case _packetTextChunk:
        await _handleTextChunkBinary(
          id: reader.readString8(),
          timestamp: reader.readUint64(),
          seq: reader.readUint16(),
          total: reader.readUint16(),
          expectedCrc: reader.readUint32(),
          payload: packet.payload,
        );
        return;
      case _packetTextDone:
        await _handleTextDoneBinary(
          id: reader.readString8(),
          timestamp: reader.readUint64(),
          total: reader.readUint16(),
          expectedCrc: reader.readUint32(),
        );
        return;
      case _packetTextMissingBatch:
        final id = reader.readString8();
        final count = reader.readUint16();
        final seqs = <int>[];
        for (int i = 0; i < count; i++) {
          seqs.add(reader.readUint16());
        }
        await _handleTextMissingBatchBinary(id, seqs);
        return;
      case _packetTextDack:
        await _handleTextDackBinary(reader.readString8());
        return;
      case _packetImageStart:
        final id = reader.readString8();
        await _handleImageStartBinary(
          id: id,
          total: reader.readUint16(),
          extension: reader.readString8(),
        );
        return;
      case _packetImageChunk:
        await _handleImageChunkBinary(
          id: reader.readString8(),
          seq: reader.readUint16(),
          total: reader.readUint16(),
          expectedCrc: reader.readUint32(),
          payload: packet.payload,
        );
        return;
      case _packetImageDone:
        await _handleImageDoneBinary(
          id: reader.readString8(),
          total: reader.readUint16(),
          expectedCrc: reader.readUint32(),
        );
        return;
      case _packetImageCack:
        await _handleImageAckBinary(
          id: reader.readString8(),
          seq: reader.readUint16(),
        );
        return;
      case _packetImageCnak:
        await _handleImageCnakBinary(
          id: reader.readString8(),
          seq: reader.readUint16(),
        );
        return;
      case _packetImageDack:
        await _handleImageDackBinary(reader.readString8());
        return;
      case _packetImageStartAck:
        await _handleImageStartAckBinary(reader.readString8());
        return;
      case _packetImageMissingBatch:
        final id = reader.readString8();
        final count = reader.readUint16();
        final seqs = <int>[];
        for (int i = 0; i < count; i++) {
          seqs.add(reader.readUint16());
        }
        await _handleImageMissingBatchBinary(id, seqs);
        return;
      case _packetRtStart:
        final id = reader.readString8();
        _setRemoteTransferLock(
          _TransferSessionType.realtimeAudio,
          id,
        );
        _incomingRealtimeAudioId = id;
        _incomingRealtimeAudioPcmBuffer.clear();
        await _startRealtimePlayback();
        return;
      case _packetRtAudio:
        await _handleRealtimeAudioBinary(
          id: reader.readString8(),
          seq: reader.readUint16(),
          payload: packet.payload,
        );
        return;
      case _packetRtStop:
        await _handleRealtimeAudioStopBinary(reader.readString8());
        return;
      case _packetAudioChunk:
        final id = reader.readString8();
        final seq = reader.readUint16();
        final total = reader.readUint16();
        final crc = reader.readUint32();
        await _handleAudioPipe(
          "CHUNK|$id|$seq|$total|$crc|${base64Encode(packet.payload)}",
        );
        return;
      case _packetAudioDone:
        final id = reader.readString8();
        final total = reader.readUint16();
        final crc = reader.readUint32();
        await _handleAudioPipe("DONE|$id|$total|$crc");
        return;
      case _packetAudioCack:
        await _handleAudioPipe(
          "CACK|${reader.readString8()}|${reader.readUint16()}",
        );
        return;
      case _packetAudioCnak:
        await _handleAudioPipe(
          "CNAK|${reader.readString8()}|${reader.readUint16()}",
        );
        return;
      case _packetAudioDack:
        await _handleAudioPipe("DACK|${reader.readString8()}");
        return;
      default:
        _log("unknown transport packet type=${packet.type}");
    }
  }
  Future<void> _handleTextPipe(String line) async {
    final parts = line.split("|");
    if (parts.isEmpty) return;

    final type = parts[0];

    if (type == "MSG") {
      if (parts.length < 4) return;

      final id = parts[1];
      final ts = int.tryParse(parts[2]);
      if (id.isEmpty || ts == null) return;

      int? expectedCrc;
      late final String text;
      if (parts.length >= 5) {
        final crcCandidate = int.tryParse(parts[3]);
        if (crcCandidate != null) {
          expectedCrc = crcCandidate;
          text = parts.sublist(4).join("|");
        } else {
          text = parts.sublist(3).join("|");
        }
      } else {
        text = parts.sublist(3).join("|");
      }

      if (expectedCrc != null) {
        final actualCrc = _crc32OfString(text);
        if (actualCrc != expectedCrc) {
          _log("text crc mismatch id=$id expected=$expectedCrc actual=$actualCrc");
          await _writeRawLine("T|CNAK|$id");
          return;
        }
      }

      final exists = await DatabaseService.messageExists(id);

      if (!exists) {
        await DatabaseService.insertMessage({
          "id": id,
          "text": text,
          "timestamp": ts,
          "status": "delivered",
          "fromUser": "REMOTE"
        });
        await _notifyIncoming("Text message received");
      }

      await _writeRawLine("T|ACK|$id");
      _clearRemoteTransferLock(type: _TransferSessionType.text, id: id);
      _loadMessagesFromDB();
    } else if (type == "ACK") {
      if (parts.length < 2) return;
      final id = parts[1];
      _textTxCache.remove(id);
      _txTextChunks.remove(id);
      await DatabaseService.updateStatus(id, "delivered");
      _loadMessagesFromDB();
    } else if (type == "CACK") {
      _log("text pipe ignoring CACK");
    } else if (type == "DACK") {
      if (parts.length < 2) return;
      final id = parts[1];
      _doneAckWaiters.remove(id);
      _txTextChunks.remove(id);
      _log("text dack cleanup id=$id");
    } else if (type == "CNAK") {
      if (parts.length < 2) return;
      final id = parts[1];
      final entry = _textTxCache[id];
      if (entry == null) {
        _log("text cnak no-cache id=$id");
        return;
      }
      await _sendTextWithCrc(
        id: id,
        timestamp: entry.timestamp,
        text: entry.text,
      );
      _log("text cnak resend id=$id");
    }
  }

  Future<void> _handleTextStartAckBinary(String id) async {
    final waiter = _textStartAckWaiters[id];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<void> _handleTextChunkBinary({
    required String id,
    required int timestamp,
    required int seq,
    required int total,
    required int expectedCrc,
    required Uint8List payload,
  }) async {
    if (id.isEmpty || total <= 0 || seq < 0 || seq >= total) return;
    final actualCrc = _crc32(payload);
    if (actualCrc != expectedCrc) return;

    _incomingTextChunks.putIfAbsent(id, () => List.generate(total, (_) => Uint8List(0)));
    if (_incomingTextChunks[id]!.length != total) {
      _incomingTextChunks[id] = List.generate(total, (_) => Uint8List(0));
    }
    _incomingTextTotals[id] = total;
    _incomingTextTimestamps[id] = timestamp;
    if (_incomingTextChunks[id]![seq].isEmpty) {
      _incomingTextChunks[id]![seq] = Uint8List.fromList(payload);
    }

    if (_incomingTextExpectedCrc.containsKey(id)) {
      await _tryFinalizeIncomingText(id);
    }
  }

  Future<void> _handleTextDoneBinary({
    required String id,
    required int timestamp,
    required int total,
    required int expectedCrc,
  }) async {
    if (id.isEmpty || total <= 0) return;
    _incomingTextExpectedCrc[id] = expectedCrc;
    _incomingTextTotals[id] = total;
    _incomingTextTimestamps[id] = timestamp;
    await _tryFinalizeIncomingText(id);
  }

  Future<void> _handleTextMissingBatchBinary(String id, List<int> seqs) async {
    final chunks = _txTextChunks[id];
    final entry = _textTxCache[id];
    if (chunks == null || entry == null || seqs.isEmpty) return;
    for (final seq in seqs) {
      if (seq < 0 || seq >= chunks.length) continue;
      await _sendTextChunkPacket(
        id: id,
        timestamp: entry.timestamp,
        seq: seq,
        total: chunks.length,
        chunk: chunks[seq],
      );
    }
  }

  Future<void> _handleTextDackBinary(String id) async {
    final waiter = _doneAckWaiters[id];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _txTextChunks.remove(id);
    _textTxCache.remove(id);
  }

  Future<void> _failIncomingText(String id, {required String reason}) async {
    _log("incoming text failed id=$id reason=$reason");
    _incomingTextChunks.remove(id);
    _incomingTextTotals.remove(id);
    _incomingTextExpectedCrc.remove(id);
    _incomingTextTimestamps.remove(id);
    _textMissingBatchCursor.remove(id);
    _textMissingRetryCount.remove(id);
    _textMissingLastMs.remove(id);
    _clearRemoteTransferLock(type: _TransferSessionType.text, id: id);
  }

  Future<void> _tryFinalizeIncomingText(String id) async {
    final chunks = _incomingTextChunks[id];
    final total = _incomingTextTotals[id];
    final expectedCrc = _incomingTextExpectedCrc[id];
    final timestamp = _incomingTextTimestamps[id];
    if (chunks == null || total == null || expectedCrc == null || timestamp == null) {
      return;
    }

    final missing = <int>[];
    for (int i = 0; i < total; i++) {
      if (i >= chunks.length || chunks[i].isEmpty) {
        missing.add(i);
      }
    }

    if (missing.isNotEmpty) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final retryMap = _textMissingRetryCount.putIfAbsent(id, () => <int, int>{});
      final lastMap = _textMissingLastMs.putIfAbsent(id, () => <int, int>{});
      final eligible = <int>[];
      for (final seq in missing) {
        final attempts = retryMap[seq] ?? 0;
        final last = lastMap[seq] ?? 0;
        if (attempts >= _textMissingRetryLimit) {
          await _failIncomingText(id, reason: "missing seq=$seq exceeded retry limit");
          return;
        }
        if (nowMs - last >= _textMissingRetryCooldownMs) {
          eligible.add(seq);
        }
      }
      if (eligible.isEmpty) return;

      final start = _textMissingBatchCursor[id] ?? 0;
      final batch = <int>[];
      for (int i = 0; i < _textMissingBatchSize; i++) {
        batch.add(eligible[(start + i) % eligible.length]);
        if (i + 1 >= eligible.length) break;
      }
      _textMissingBatchCursor[id] =
          eligible.isEmpty ? 0 : (start + batch.length) % eligible.length;
      for (final seq in batch) {
        retryMap[seq] = (retryMap[seq] ?? 0) + 1;
        lastMap[seq] = nowMs;
      }
      await _sendTextMissingBatchPacket(id, batch);
      return;
    }

    final full = <int>[];
    for (final chunk in chunks) {
      full.addAll(chunk);
    }
    final actualCrc = _crc32(full);
    if (actualCrc != expectedCrc) {
      final allSeqs = List<int>.generate(total, (i) => i);
      await _sendTextMissingBatchPacket(
        id,
        allSeqs.take(_textMissingBatchSize).toList(),
      );
      return;
    }

    final text = utf8.decode(full, allowMalformed: true);
    final exists = await DatabaseService.messageExists(id);
    if (!exists) {
      await DatabaseService.insertMessage({
        "id": id,
        "text": text,
        "timestamp": timestamp,
        "status": "delivered",
        "fromUser": "REMOTE"
      });
      await _notifyIncoming("Text message received");
    }

    _incomingTextChunks.remove(id);
    _incomingTextTotals.remove(id);
    _incomingTextExpectedCrc.remove(id);
    _incomingTextTimestamps.remove(id);
    _textMissingBatchCursor.remove(id);
    _textMissingRetryCount.remove(id);
    _textMissingLastMs.remove(id);
    await _sendTextDackPacket(id);
    _clearRemoteTransferLock(type: _TransferSessionType.text, id: id);
    _loadMessagesFromDB();
  }
Future<void> _handleAudioPipe(String line) async {

  final parts = line.split("|");
  if (parts.isEmpty) return;

  final type = parts[0];

  if (type == "CHUNK") {
    if (parts.length < 5) return;

    final id = parts[1];
    final seq = int.tryParse(parts[2]);
    final total = int.tryParse(parts[3]);
    if (id.isEmpty || seq == null || total == null || seq < 0 || total <= 0 || seq >= total) {
      return;
    }

    // On noisy links, corrupted/truncated lines appear often.
    // Do not CNAK immediately here; DONE stage requests only truly missing chunks.
    if (parts.length < 6) {
      _log("audio chunk malformed drop id=$id seq=$seq parts=${parts.length}");
      return;
    }

    int? expectedCrc;
    late final String payload;
    final crcCandidate = int.tryParse(parts[4]);
    if (crcCandidate != null) {
      expectedCrc = crcCandidate;
      payload = parts.sublist(5).join("|");
    } else {
      _log("audio chunk invalid crc header drop id=$id seq=$seq");
      return;
    }

    List<int> decoded;
    try {
      decoded = base64Decode(payload);
    } catch (_) {
      _log("audio chunk base64 decode failed drop id=$id seq=$seq");
      return;
    }

    if (expectedCrc != null) {
      final actualCrc = _crc32(decoded);
      if (actualCrc != expectedCrc) {
        await _writeRawLine("A|CNAK|$id|$seq");
        _log("audio chunk crc mismatch id=$id seq=$seq expected=$expectedCrc actual=$actualCrc");
        return;
      }
    }

    _audioLastSeenMs[id] = DateTime.now().millisecondsSinceEpoch;
    audioBuffer.putIfAbsent(id, () => List.generate(total, (_) => []));
    if (audioBuffer[id]!.length != total) {
      audioBuffer[id] = List.generate(total, (_) => []);
    }

    if (audioBuffer[id]![seq].isEmpty) {
      audioBuffer[id]![seq] = decoded;
    }

    await _writeRawLine("A|CACK|$id|$seq");
  }

  else if (type == "DONE") {
    if (parts.length < 2) return;

    final id = parts[1];
    final alreadySaved = await DatabaseService.messageExists(id);
    if (alreadySaved) {
      await _writeRawLine("A|DACK|$id");
      return;
    }
    if (!audioBuffer.containsKey(id)) return;

    final total = parts.length >= 3 ? int.tryParse(parts[2]) : null;
    final expectedCrc = parts.length >= 4 ? int.tryParse(parts[3]) : null;

    if (total != null && total > 0 && audioBuffer[id]!.length != total) {
      for (int i = 0; i < total; i++) {
        if (i >= audioBuffer[id]!.length || audioBuffer[id]![i].isEmpty) {
          await _writeRawLine("A|CNAK|$id|$i");
        }
      }
      _log("audio done total mismatch id=$id total=$total have=${audioBuffer[id]!.length}");
      return;
    }

    if (audioBuffer[id]!.any((c) => c.isEmpty)) {
      for (int i = 0; i < audioBuffer[id]!.length; i++) {
        if (audioBuffer[id]![i].isEmpty) {
          await _writeRawLine("A|CNAK|$id|$i");
        }
      }
      _log("audio done but chunks missing id=$id");
      return;
    }

    final full = <int>[];
    for (final p in audioBuffer[id]!) {
      full.addAll(p);
    }

    if (expectedCrc != null) {
      final actualCrc = _crc32(full);
      if (actualCrc != expectedCrc) {
        for (int i = 0; i < audioBuffer[id]!.length; i++) {
          await _writeRawLine("A|CNAK|$id|$i");
        }
        _log("audio done crc mismatch id=$id expected=$expectedCrc actual=$actualCrc");
        return;
      }
    }

    final pcm = await _codec2Decode(Uint8List.fromList(full));
    final polishedPcm = _polishRecordedRxPcm(pcm);
    final wav = _buildWavFromPcm(polishedPcm);

    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/$id.wav");

    await file.writeAsBytes(wav);
    await _writeRawLine("A|DACK|$id");

    final exists = await DatabaseService.messageExists(id);
    if (!exists) {
      await DatabaseService.insertMessage({
        "id": id,
        "text": file.path,
        "timestamp": DateTime.now().millisecondsSinceEpoch,
        "status": "delivered",
        "fromUser": "REMOTE",
        "isImage": 2,
      });
      await _notifyIncoming("Audio message received");
    }

    audioBuffer.remove(id);
    _loadMessagesFromDB();
  }

  else if (type == "CACK") {
    if (parts.length < 3) return;

    final id = parts[1];
    final seq = int.tryParse(parts[2]);
    if (seq == null) return;

    final key = "$id:$seq";
    final waiter = _chunkAckWaiters[key];

    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      _log("cack matched id=$id seq=$seq");
    } else {
      _earlyChunkAcks.add(key);
      _log("early cack stored id=$id seq=$seq");
    }
  }

  else if (type == "DACK") {
    if (parts.length < 2) return;
    final id = parts[1];

    final waiter = _doneAckWaiters[id];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      _log("dack matched id=$id");
    }

    _mediaCache.remove(id);
    _mediaChunkSize.remove(id);
    _mediaTotalChunks.remove(id);
    _mediaChunkType.remove(id);
  }

  else if (type == "CNAK") {
    if (parts.length < 3) return;

    final id = parts[1];
    final seq = int.tryParse(parts[2]);
    if (seq == null || seq < 0) return;

    final bytes = _mediaCache[id];
    final chunkSize = _mediaChunkSize[id];
    final total = _mediaTotalChunks[id];

    if (bytes == null || chunkSize == null || total == null) return;

    final start = seq * chunkSize;
    if (start >= bytes.length) return;

    int end = start + chunkSize;
    if (end > bytes.length) end = bytes.length;

    final chunk = bytes.sublist(start, end);
    final chunkCrc = _crc32(chunk);
    await _writeRawLine("A|CHUNK|$id|$seq|$total|$chunkCrc|${base64Encode(chunk)}");

    _log("cnak resend id=$id seq=$seq");
  }

  else if (type == "ACK") {
    if (parts.length < 2) return;
    final id = parts[1];
    await DatabaseService.updateStatus(id, "delivered");
    _loadMessagesFromDB();
  }
}
  Future<void> _handleRealtimeAudioBinary({
    required String id,
    required int seq,
    required Uint8List payload,
  }) async {
    if (id.isEmpty || payload.isEmpty) return;
    _setRemoteTransferLock(_TransferSessionType.realtimeAudio, id);
    final pcm = await _codec2Decode(payload);
    if (pcm.isEmpty) {
      _log("realtime audio decode empty id=$id seq=$seq");
      return;
    }
    if (_incomingRealtimeAudioId != id) {
      _incomingRealtimeAudioId = id;
      _incomingRealtimeAudioPcmBuffer.clear();
    }
    _incomingRealtimeAudioPcmBuffer.addAll(pcm);
    await _playRealtimePcm(pcm);
  }

  Future<void> _handleRealtimeAudioStopBinary(String id) async {
    _clearRemoteTransferLock(
      type: _TransferSessionType.realtimeAudio,
      id: id,
    );
    await _stopRealtimePlayback();
    if (_incomingRealtimeAudioId == id &&
        _incomingRealtimeAudioPcmBuffer.isNotEmpty) {
      await _saveIncomingRealtimeAudioMessage(
        id,
        Uint8List.fromList(_incomingRealtimeAudioPcmBuffer),
      );
    }
    _incomingRealtimeAudioId = null;
    _incomingRealtimeAudioPcmBuffer.clear();
  }
  Future<img.Image?> _decodeAnyToImage(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded != null) return decoded;

    try {
      final frames = await decodeAvif(bytes);
      if (frames.isEmpty) return null;
      final ui.Image uiImage = frames.first.image;
      final byteData =
          await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      return img.Image.fromBytes(
        width: uiImage.width,
        height: uiImage.height,
        bytes: byteData.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _encodeAvifWithQuality(
    Uint8List inputBytes,
    int quality,
  ) async {
    final q = _qualityToQuantizer(quality);
    return encodeAvif(
      inputBytes,
      speed: 10,
      maxThreads: 4,
      minQuantizer: q,
      maxQuantizer: q,
      minQuantizerAlpha: q,
      maxQuantizerAlpha: q,
      keepExif: false,
    );
  }

  Future<Uint8List> _compressToTargetAvif(img.Image source) async {
    int low = _minQuality;
    int high = _maxQuality;

    final inputBytes = Uint8List.fromList(img.encodePng(source));
    Uint8List bestBytes = await _encodeAvifWithQuality(inputBytes, _minQuality);
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final bytes = await _encodeAvifWithQuality(inputBytes, mid);
      final sizeKb = bytes.length / 1024.0;

      if (sizeKb <= _targetSizeKb) {
        bestBytes = bytes;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return bestBytes;
  }
  Future<Uint8List> _compressToTargetAvifWithLimit(
    img.Image source, {
    required int targetSizeKb,
  }) async {
    int low = _minQuality;
    int high = _maxQuality;

    final inputBytes = Uint8List.fromList(img.encodePng(source));
    Uint8List bestBytes = await _encodeAvifWithQuality(inputBytes, _minQuality);
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final bytes = await _encodeAvifWithQuality(inputBytes, mid);
      final sizeKb = bytes.length / 1024.0;

      if (sizeKb <= targetSizeKb) {
        bestBytes = bytes;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return bestBytes;
  }

  Future<Uint8List> _whatsappStyleOptimizeBytes(Uint8List bytes) async {
    final decoded = await _decodeAnyToImage(bytes);
    if (decoded == null) return Uint8List(0);

    final resized = _resizeImage(decoded);
    final denoised = _denoiseImage(resized);
    return _compressToTargetAvif(denoised);
  }

  Future<Uint8List> _whatsappStyleOptimize(File file) async {
    return _whatsappStyleOptimizeBytes(await file.readAsBytes());
  }
  Future<Uint8List> _whatsappStyleOptimizeBytesAdaptive(
    Uint8List bytes, {
    required int maxDimension,
    required int targetSizeKb,
  }) async {
    final decoded = await _decodeAnyToImage(bytes);
    if (decoded == null) return Uint8List(0);

    final resized = _resizeImageToMax(decoded, maxDimension);
    final denoised = _denoiseImage(resized);
    return _compressToTargetAvifWithLimit(
      denoised,
      targetSizeKb: targetSizeKb,
    );
  }

  Future<_CompressedImageResult> _compressSenderImage({
    required File file,
    required int maxDimension,
    required int targetSizeKb,
  }) async {
    try {
      final nativeCompressed = await _codec2Channel.invokeMethod<Map<dynamic, dynamic>>(
        "compressImageCv2",
        {
          "path": file.path,
          "maxDimension": maxDimension,
          "targetSizeKb": targetSizeKb,
          "minQuality": _minQuality,
          "maxQuality": _maxQuality,
          "format": _nativeImageFormat,
        },
      );

      final bytes = nativeCompressed?["bytes"];
      final format = nativeCompressed?["format"]?.toString().toLowerCase();
      if (bytes is Uint8List && bytes.isNotEmpty) {
        _log("sender cv2 compression success bytes=${bytes.length}");
        return _CompressedImageResult(
          bytes: bytes,
          extension: format == "jpg" || format == "jpeg"
              ? "jpg"
              : "webp",
        );
      }
    } catch (e) {
      _log("sender cv2 compression failed: $e");
    }

    _log("sender compression fallback to Dart AVIF pipeline");
    final fallback = await _whatsappStyleOptimizeBytesAdaptive(
      await file.readAsBytes(),
      maxDimension: maxDimension,
      targetSizeKb: targetSizeKb,
    );
    return _CompressedImageResult(bytes: fallback, extension: "avif");
  }

  BluetoothCharacteristic? targetChar;
  static const MethodChannel _codec2Channel =
      MethodChannel("com.example.lora_voice_app/codec2");

  final TextEditingController controller = TextEditingController();
  final List<Widget> chatMessages = [];
  final ScrollController _scrollController = ScrollController();
  Map<String, List<List<int>>> audioBuffer = {};
  Map<String, int> audioTotal = {};
  final Map<String, List<Uint8List>> _imageBuffer = {};
  final Map<String, int> _imageTotal = {};
  final Map<String, String> _imageExtension = {};
  final Map<String, int> _imageExpectedCrc = {};
  final Map<String, int> _imageMissingBatchCursor = {};
  String? _activeIncomingImageId;
  final Map<String, List<Uint8List>> _txImageChunks = {};
  final Map<String, int> _audioLastSeenMs = {};
  final Map<String, int> _imageLastSeenMs = {};
  final Map<String, Map<int, int>> _cnakRetryCount = {};
  final Map<String, Map<int, int>> _cnakLastMs = {};
  final Map<String, Completer<void>> _imageStartAckWaiters = {};
  final Map<String, Completer<void>> _chunkAckWaiters = {};
  final Map<String, Completer<void>> _doneAckWaiters = {};
  final Map<String, Completer<void>> _textStartAckWaiters = {};
  final Map<String, List<int>> _mediaCache = {};
  final Map<String, int> _mediaChunkSize = {};
  final Map<String, int> _mediaTotalChunks = {};
  final Map<String, String> _mediaChunkType = {};
  final Map<String, _TextTxCacheEntry> _textTxCache = {};
  final Map<String, List<Uint8List>> _txTextChunks = {};
  final Map<String, List<Uint8List>> _incomingTextChunks = {};
  final Map<String, int> _incomingTextTotals = {};
  final Map<String, int> _incomingTextExpectedCrc = {};
  final Map<String, int> _incomingTextTimestamps = {};
  final Map<String, int> _textMissingBatchCursor = {};
  final Map<String, Map<int, int>> _textMissingRetryCount = {};
  final Map<String, Map<int, int>> _textMissingLastMs = {};
 
  final AudioRecorder _audioRecorder = AudioRecorder();
  final PlayerStream _realtimePlayer = PlayerStream();
  String? _recordingPath;
  bool _isRecordingAudio = false;
  final List<int> _incomingPacketBuffer = [];
  bool _isSendingMedia = false;
  bool _isSendingText = false;
  bool _isPlayingRealtimeAudio = false;
  String? _remoteActiveTransferId;
  _TransferSessionType? _remoteActiveTransferType;
  String? _activeRealtimeAudioId;
  int _realtimeAudioSeq = 0;
  final List<int> _realtimeAudioFrameBuffer = [];
  final List<int> _outgoingRealtimeAudioPcmBuffer = [];
  final List<int> _incomingRealtimeAudioPcmBuffer = [];
  final Queue<int> _realtimePlaybackBuffer = Queue<int>();
  String? _incomingRealtimeAudioId;
  bool isReady = false;
  Timer? _retryTimer;
  Timer? _imageCleanupTimer;
  Timer? _recordStopTimer;
  Timer? _recordingUiTimer;
  Timer? _realtimePlaybackDrainTimer;
  DateTime? _recordingStartedAt;
  Future<void> _writeQueue = Future.value();

  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription<Uint8List>? _realtimeAudioSubscription;
  bool _realtimePlayerReady = false;
  bool _realtimePlaybackStarted = false;

  @override
  void initState() {
    super.initState();
    _log("initState device=${widget.device.remoteId.str}");
    _initConnection();
    _loadMessagesFromDB();
    _startRetryEngine();
    _startImageCleanupEngine();
  }

  @override
  void dispose() {
    _log("dispose device=${widget.device.remoteId.str}");
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    _realtimeAudioSubscription?.cancel();
    _retryTimer?.cancel();
    _imageCleanupTimer?.cancel();
    _recordStopTimer?.cancel();
    _recordingUiTimer?.cancel();
    _realtimePlaybackDrainTimer?.cancel();
    _audioRecorder.dispose();
    _stopRealtimePlayback();
    _realtimePlayer.stop();
    _scrollController.dispose();
    widget.device.disconnect();
    super.dispose();
  }
  Future<void> pickImage() async {
    _log("pickImage open source picker");
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text("Camera"),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text("Gallery"),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;
    _log("pickImage source=$source");
    final XFile? picked = await picker.pickImage(source: source);
    if (picked == null) return;
    _log("pickImage picked path=${picked.path}");
    await sendImage(File(picked.path));
  }

  Future<void> sendImage(File file) async {
 if (!_canStart(MediaMode.image) || !_canStartTransfer) {
  _log(
    "sendImage blocked "
    "mode=$_mediaMode remoteLocked=$_hasRemoteActiveTransfer canStart=$_canStartTransfer",
  );
  return;
}

await _resetMedia();
_mediaMode = MediaMode.image;
_markImageActivity("send_image_start");

  try {

    if (targetChar == null) {
      _log("sendImage skipped: targetChar null");
      return;
    }

    _log("sendImage start file=${file.path}");
    await _transportCooldown();
    final compressed =
        await _compressUntilPacketLimit(file);

    // ===== DEBUG IMAGE SIZE =====
    try {
      final decoded =
          img.decodeImage(compressed.bytes);

      if (decoded != null) {
        _log(
          "COMPRESSED IMAGE → "
          "width=${decoded.width} "
          "height=${decoded.height} "
          "bytes=${compressed.bytes.length}"
        );
      } else {
        _log("COMPRESSED IMAGE decode failed");
      }
    } catch (e) {
      _log("dimension log error: $e");
    }

    if (compressed.bytes.isEmpty) {
      _log("sendImage failed: compressed bytes empty");
      return;
    }

    _log(
      "sendImage compressed bytes=${compressed.bytes.length} "
      "ext=${compressed.extension}"
    );

    await transmitImageBytes(
      compressed.bytes,
      extension: compressed.extension,
    );

  } finally {

    /// ✅ ALWAYS executed
    _mediaMode = MediaMode.idle;
    _markImageActivity("send_image_end");
  }
}

  Future<_CompressedImageResult> _compressSenderImageWithCv2(File file) async {
    return _compressSenderImage(
      file: file,
      maxDimension: _maxDimension,
      targetSizeKb: _targetSizeKb,
    );
  }
  Future<_CompressedImageResult>
    _compressUntilPacketLimit(File file) async {

  int dimension = _maxDimension;
  int targetKb = _targetSizeKb;
  final targetBytes = _targetSizeKb * 1024;

  _CompressedImageResult result =
      await _compressSenderImageWithCv2(file);

  int packets =
      _estimatePacketCount(result.bytes.length);
  bool withinSize =
      result.bytes.isNotEmpty &&
      result.bytes.length <= targetBytes;

  _log(
      "INITIAL packets=$packets bytes=${result.bytes.length} withinSize=$withinSize");

  int iteration = 0;

  while ((packets > _maxAllowedPackets || !withinSize) &&
      iteration < 7) {

    iteration++;

    /// progressively stronger compression
    dimension = (dimension * 0.80).round();
    targetKb = (targetKb * 0.70).round();

    if (dimension < 240) dimension = 240;
    if (targetKb < 5) targetKb = 5;

    _log(
        "RECOMPRESS iteration=$iteration "
        "dimension=$dimension targetKb=$targetKb");

    result = await _compressSenderImage(
      file: file,
      maxDimension: dimension,
      targetSizeKb: targetKb,
    );

    packets =
        _estimatePacketCount(result.bytes.length);
    withinSize =
        result.bytes.isNotEmpty &&
        result.bytes.length <= targetBytes;

    _log(
        "AFTER recompress packets=$packets bytes=${result.bytes.length} withinSize=$withinSize");
  }

  _log(
      "FINAL packets=$packets bytes=${result.bytes.length} withinSize=$withinSize");

  return result;
}
  Future<_CompressedImageResult> _compressReceiverImageWithCv2(
    Uint8List bytes,
  ) async {
    try {
      final nativeCompressed = await _codec2Channel.invokeMethod<Map<dynamic, dynamic>>(
        "compressImageBytesCv2",
        {
          "bytes": bytes,
          "maxDimension": _maxDimension,
          "targetSizeKb": _targetSizeKb,
          "minQuality": _minQuality,
          "maxQuality": _maxQuality,
          "format": _nativeImageFormat,
        },
      );

      final outBytes = nativeCompressed?["bytes"];
      final format = nativeCompressed?["format"]?.toString().toLowerCase();
      if (outBytes is Uint8List && outBytes.isNotEmpty) {
        _log("receiver cv2 compression success bytes=${outBytes.length}");
        return _CompressedImageResult(
          bytes: outBytes,
          extension: format == "jpg" || format == "jpeg"
              ? "jpg"
              : "webp",
        );
      }
    } catch (e) {
      _log("receiver cv2 compression failed: $e");
    }

    _log("receiver compression fallback to Dart AVIF pipeline");
    final fallback = await _whatsappStyleOptimizeBytes(bytes);
    return _CompressedImageResult(bytes: fallback, extension: "avif");
  }

  Future<void> transmitImageBytes(
    List<int> bytes, {
    String extension = "avif",
  }) async {
    if (targetChar == null || _isSendingMedia) {
      _log("transmitImageBytes skipped targetChar=${targetChar != null} isSendingMedia=$_isSendingMedia");
      return;
    }

    final id = "IMG_${DateTime.now().millisecondsSinceEpoch}";
    _log("transmitImageBytes id=$id bytes=${bytes.length} ext=$extension");
    final now = DateTime.now().millisecondsSinceEpoch;
    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/$id.$extension");
    await file.writeAsBytes(bytes);

    await DatabaseService.insertMessage({
      "id": id,
      "text": file.path,
      "timestamp": now,
      "status": "pending",
      "fromUser": "ME",
      "isImage": 1,
      "retryCount": 0,
      "lastAttempt": 0
    });
    _loadMessagesFromDB();

    _isSendingMedia = true;
    try {
      await _sendImageChunks(
        id: id,
        bytes: bytes,
        extension: extension,
      );
    } catch (_) {
      _log("transmitImageBytes failed id=$id");
      await DatabaseService.updateStatus(id, "failed");
      _loadMessagesFromDB();
    } finally {
      _log("transmitImageBytes end id=$id");
      _isSendingMedia = false;
      _loadMessagesFromDB();
    }
  }

  Future<void> _sendImageStartPacket({
    required String id,
    required int total,
    required String extension,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(total))
      ..add(_string8(extension));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageStart,
        header: header.takeBytes(),
      ),
    );
  }

  Future<void> _sendImageChunkPacket({
    required String id,
    required int seq,
    required int total,
    required Uint8List chunk,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(seq))
      ..add(_u16Bytes(total))
      ..add(_u32Bytes(_crc32(chunk)));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageChunk,
        header: header.takeBytes(),
        payload: chunk,
      ),
    );
  }

  Future<void> _sendImageDonePacket({
    required String id,
    required int total,
    required int imageCrc,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(total))
      ..add(_u32Bytes(imageCrc));
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageDone,
        header: header.takeBytes(),
      ),
    );
  }

  Future<void> _sendImageCackPacket({
    required String id,
    required int seq,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(seq));
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetImageCack, header: header.takeBytes()),
    );
  }

  Future<void> _sendImageCnakPacket({
    required String id,
    required int seq,
  }) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(seq));
    await _writeTransportPacket(
      _buildTransportPacket(type: _packetImageCnak, header: header.takeBytes()),
    );
  }

  Future<void> _sendImageDackPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageDack,
        header: _string8(id),
      ),
    );
  }

  Future<void> _sendImageStartAckPacket(String id) async {
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageStartAck,
        header: _string8(id),
      ),
    );
  }

  Future<void> _sendImageMissingBatchPacket(
    String id,
    List<int> missingSeqs,
  ) async {
    final header = BytesBuilder(copy: false)
      ..add(_string8(id))
      ..add(_u16Bytes(missingSeqs.length));
    for (final seq in missingSeqs) {
      header.add(_u16Bytes(seq));
    }
    await _writeTransportPacket(
      _buildTransportPacket(
        type: _packetImageMissingBatch,
        header: header.takeBytes(),
      ),
    );
  }

  Future<void> _saveIncomingRealtimeAudioMessage(String id, Uint8List pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    final wav = _buildWavFromPcm(pcmBytes);
    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/$id.wav");
    await file.writeAsBytes(wav);

    final exists = await DatabaseService.messageExists(id);
    if (!exists) {
      await DatabaseService.insertMessage({
        "id": id,
        "text": file.path,
        "timestamp": DateTime.now().millisecondsSinceEpoch,
        "status": "delivered",
        "fromUser": "REMOTE",
        "isImage": 2,
      });
      await _notifyIncoming("Voice message received");
    }
    _loadMessagesFromDB();
  }

  Future<void> _finalizeIncomingRealtimeAudioSession() async {
    final id = _incomingRealtimeAudioId;
    if (id != null && _incomingRealtimeAudioPcmBuffer.isNotEmpty) {
      await _saveIncomingRealtimeAudioMessage(
        id,
        Uint8List.fromList(_incomingRealtimeAudioPcmBuffer),
      );
    }
    _incomingRealtimeAudioPcmBuffer.clear();
    _incomingRealtimeAudioId = null;
    _clearRemoteTransferLock(type: _TransferSessionType.realtimeAudio, id: id);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _failIncomingImage(
    String id, {
    required String reason,
  }) async {
    _log("incoming image failed id=$id reason=$reason");
    _imageBuffer.remove(id);
    _imageTotal.remove(id);
    _imageExtension.remove(id);
    _imageExpectedCrc.remove(id);
    _imageMissingBatchCursor.remove(id);
    _imageLastSeenMs.remove(id);
    _cnakRetryCount.remove(id);
    _cnakLastMs.remove(id);
    if (_activeIncomingImageId == id) {
      _activeIncomingImageId = null;
    }
    _clearRemoteTransferLock(type: _TransferSessionType.image, id: id);
  }

  Future<void> _tryFinalizeIncomingImage(String id) async {
    final chunks = _imageBuffer[id];
    final total = _imageTotal[id];
    final expectedCrc = _imageExpectedCrc[id];
    if (chunks == null || total == null || expectedCrc == null) return;

    final missing = <int>[];
    for (int i = 0; i < total; i++) {
      if (i >= chunks.length || chunks[i].isEmpty) {
        missing.add(i);
      }
    }

    if (missing.isNotEmpty) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final retryMap = _cnakRetryCount.putIfAbsent(id, () => <int, int>{});
      final lastMap = _cnakLastMs.putIfAbsent(id, () => <int, int>{});
      final eligibleMissing = <int>[];

      for (final seq in missing) {
        final attempts = retryMap[seq] ?? 0;
        final lastRequestMs = lastMap[seq] ?? 0;

        if (attempts >= _imageMissingRetryLimit) {
          await _failIncomingImage(
            id,
            reason: "missing seq=$seq exceeded retry limit",
          );
          return;
        }

        if (nowMs - lastRequestMs >= _imageMissingRetryCooldownMs) {
          eligibleMissing.add(seq);
        }
      }

      if (eligibleMissing.isEmpty) {
        _log("img missing batch deferred id=$id waiting_for_cooldown");
        return;
      }

      final start = _imageMissingBatchCursor[id] ?? 0;
      final batch = <int>[];
      for (int i = 0; i < _imageMissingBatchSize; i++) {
        batch.add(eligibleMissing[(start + i) % eligibleMissing.length]);
        if (i + 1 >= eligibleMissing.length) break;
      }
      _imageMissingBatchCursor[id] =
          eligibleMissing.isEmpty ? 0 : (start + batch.length) % eligibleMissing.length;

      for (final seq in batch) {
        retryMap[seq] = (retryMap[seq] ?? 0) + 1;
        lastMap[seq] = nowMs;
      }

      await _sendImageMissingBatchPacket(id, batch);
      _log(
        "img missing batch request "
        "id=$id count=${batch.length} seqs=${batch.join(',')}",
      );
      return;
    }

    final full = <int>[];
    for (final chunk in chunks) {
      full.addAll(chunk);
    }

    final actualCrc = _crc32(full);
    if (actualCrc != expectedCrc) {
      final allSeqs = List<int>.generate(total, (i) => i);
      await _sendImageMissingBatchPacket(
        id,
        allSeqs.take(_imageMissingBatchSize).toList(),
      );
      _log("img full crc mismatch id=$id expected=$expectedCrc actual=$actualCrc");
      return;
    }

    _imageBuffer.remove(id);
    _imageTotal.remove(id);
    final ext = _imageExtension.remove(id) ?? "bin";
    _imageExpectedCrc.remove(id);
    _imageMissingBatchCursor.remove(id);
    _imageLastSeenMs.remove(id);
    if (_activeIncomingImageId == id) {
      _activeIncomingImageId = null;
    }
    _cnakRetryCount.remove(id);
    _cnakLastMs.remove(id);
    _markImageActivity("recv_img_done");
    _clearRemoteTransferLock(type: _TransferSessionType.image, id: id);

    await _onImageComplete(id, full, extension: ext);
    await _sendImageDackPacket(id);
  }

  Future<void> _sendImageChunks({
    required String id,
    required List<int> bytes,
    String extension = "avif",
  }) async {
    if (targetChar == null) {
      _log("sendImageChunks skipped: targetChar null id=$id");
      return;
    }

    const int chunkSize = _imageChunkSizeBytes;
    final chunks = <Uint8List>[];
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
      chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    final total = chunks.length;
    _log("sendImageChunks start id=$id bytes=${bytes.length} total=$total");
    _isSendingMedia = true;
    _clearAckStateForId(id);
    _txImageChunks[id] = chunks;
    _mediaChunkSize[id] = chunkSize; // kept for diagnostics
    _mediaTotalChunks[id] = total;
    _mediaChunkType[id] = "IMG_CHUNK_RAW";

    try {
      final startAckCompleter = Completer<void>();
      _imageStartAckWaiters[id] = startAckCompleter;
      await _sendImageStartPacket(id: id, total: total, extension: extension);
      try {
        await startAckCompleter.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        _log("img start ack timeout id=$id");
        await DatabaseService.updateStatus(id, "failed");
        _clearAckStateForId(id);
        _txImageChunks.remove(id);
        _mediaChunkSize.remove(id);
        _mediaTotalChunks.remove(id);
        _mediaChunkType.remove(id);
        _loadMessagesFromDB();
        return;
      } finally {
        if (_imageStartAckWaiters[id] == startAckCompleter) {
          _imageStartAckWaiters.remove(id);
        }
      }

      for (int i = 0; i < total; i++) {
        final chunk = chunks[i];
        await _sendImageChunkPacket(
          id: id,
          seq: i,
          total: total,
          chunk: chunk,
        );
        await Future.delayed(const Duration(milliseconds: 70));
      }

      final doneCompleter = Completer<void>();
      _doneAckWaiters[id] = doneCompleter;
      final imageCrc = _crc32(bytes);
      await _sendImageDonePacket(id: id, total: total, imageCrc: imageCrc);

      try {
        await doneCompleter.future.timeout(const Duration(seconds: 90));
        _log("img done ack id=$id");
        await DatabaseService.updateStatus(id, "delivered");
      } catch (_) {
        _log("img done ack timeout id=$id");
        _clearAckStateForId(id);
        _txImageChunks.remove(id);
        _mediaChunkSize.remove(id);
        _mediaTotalChunks.remove(id);
        _mediaChunkType.remove(id);
      } finally {
        if (_doneAckWaiters[id] == doneCompleter) {
          _doneAckWaiters.remove(id);
        }
      }
      _loadMessagesFromDB();
    } finally {
      _log("sendImageChunks end id=$id");
      _isSendingMedia = false;
    }
  }

  Future<void> startAudioRecording() async {
  if (!_canStart(MediaMode.recording) || !_canStartTransfer) {
  _log(
    "record blocked "
    "mode=$_mediaMode remoteLocked=$_hasRemoteActiveTransfer canStart=$_canStartTransfer",
  );
  return;
}
  await _resetMedia();
  _mediaMode = MediaMode.recording;

  try {

    if (_isRecordingAudio ||
        _isSendingMedia ||
        !isReady ||
        targetChar == null) {

      _log(
        "startAudioRecording skipped "
        "isRecording=$_isRecordingAudio "
        "isSending=$_isSendingMedia "
        "isReady=$isReady "
        "hasChar=${targetChar != null}"
      );
      return;
    }

    if (!await _audioRecorder.hasPermission()) {
      _log("startAudioRecording skipped: no recorder permission");
      return;
    }

    _clearPttBuffers("start_audio_recording");
    await _transportCooldown();
    await _audioStabilizationCooldown();

    final dir =
        await getApplicationDocumentsDirectory();

    final id =
        "AUD_${DateTime.now().millisecondsSinceEpoch}";

    _recordingPath =
        "${dir.path}/$id.wav";

    _activeRealtimeAudioId = id;
    _realtimeAudioSeq = 0;
    _realtimeAudioFrameBuffer.clear();
    _outgoingRealtimeAudioPcmBuffer.clear();
    await _sendRealtimeAudioStartPacket(id);

    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 8000,
        numChannels: 1,
      ),
    );

    _realtimeAudioSubscription?.cancel();
    _realtimeAudioSubscription = stream.listen(
      (chunk) async {
        _outgoingRealtimeAudioPcmBuffer.addAll(chunk);
        _realtimeAudioFrameBuffer.addAll(chunk);
        while (_realtimeAudioFrameBuffer.length >= 640) {
          await _flushRealtimeAudioFrame();
        }
      },
      onError: (Object error) {
        _log("realtime audio stream error: $error");
      },
    );

    _recordStopTimer?.cancel();
    _recordingUiTimer?.cancel();
    _recordingStartedAt = DateTime.now();

    _recordStopTimer =
        Timer(const Duration(seconds: 15), () {
      if (_isRecordingAudio) {
        stopAudioRecordingAndSend();
      }
    });

    _recordingUiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isRecordingAudio) return;
      setState(() {});
    });

    if (mounted) {
      setState(() => _isRecordingAudio = true);
    }

    _log("startAudioRecording realtime started id=$id");

  } finally {

    /// ✅ recording mode remains only if active
    if (!_isRecordingAudio) {
      _mediaMode = MediaMode.idle;
    }
  }
}

  Future<void> stopAudioRecordingAndSend() async {

  if (!_isRecordingAudio) {
    _log("stopAudioRecordingAndSend skipped: not recording");
    return;
  }

  try {

    _recordStopTimer?.cancel();
    _recordingUiTimer?.cancel();
    await _realtimeAudioSubscription?.cancel();
    _realtimeAudioSubscription = null;
    await _audioRecorder.stop();
    await _flushRealtimeAudioFrame(allowPadding: true);
    if (_activeRealtimeAudioId != null) {
      await _sendRealtimeAudioStopPacket(_activeRealtimeAudioId!);
      if (_recordingPath != null && _outgoingRealtimeAudioPcmBuffer.isNotEmpty) {
        final pcmBytes = _enhanceRecordedTxPcm(
          Uint8List.fromList(_outgoingRealtimeAudioPcmBuffer),
        );
        final wavBytes = _buildWavFromPcm(pcmBytes);
        final file = File(_recordingPath!);
        await file.writeAsBytes(wavBytes);

        final exists = await DatabaseService.messageExists(_activeRealtimeAudioId!);
        if (!exists) {
          await DatabaseService.insertMessage({
            "id": _activeRealtimeAudioId!,
            "text": file.path,
            "timestamp": DateTime.now().millisecondsSinceEpoch,
            "status": "delivered",
            "fromUser": "ME",
            "isImage": 2,
          });
        }
        _loadMessagesFromDB();
      }
    }

    if (mounted) {
      setState(() => _isRecordingAudio = false);
    }
    _recordingStartedAt = null;
    _recordingPath = null;
    _activeRealtimeAudioId = null;
    _realtimeAudioSeq = 0;
    _realtimeAudioFrameBuffer.clear();
    _outgoingRealtimeAudioPcmBuffer.clear();
    _log("stopAudioRecordingAndSend realtime stopped");

  } finally {

    /// ✅ ALWAYS reset media state
    _mediaMode = MediaMode.idle;
  }
}

  Future<void> _toggleRealtimeRecordingTap() async {
    if (_isRecordingAudio) {
      _log("mic tap stop");
      await stopAudioRecordingAndSend();
      return;
    }

    if (!_canStartTransfer) {
      _log(
        "mic tap blocked "
        "remoteLocked=$_hasRemoteActiveTransfer canStart=$_canStartTransfer",
      );
      return;
    }

    _log("mic tap start");
    await startAudioRecording();
  }

  Future<void> _openRealtimeAudioPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => realtime_audio.ChatScreen(
          device: widget.device,
          screenTitle: "Realtime Audio",
          reuseExistingConnection: true,
        ),
      ),
    );
  }

  String _formatRecordingElapsed() {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) return "0:00";
    final elapsed = DateTime.now().difference(startedAt);
    final maxSeconds = 15;
    final totalSeconds = elapsed.inSeconds.clamp(0, maxSeconds);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return "$minutes:${seconds.toString().padLeft(2, '0')}";
  }

  Future<void> transmitAudioFile(File wavFile) async {
    if (targetChar == null || _isSendingMedia) {
      _log("transmitAudioFile skipped targetChar=${targetChar != null} isSendingMedia=$_isSendingMedia");
      return;
    }

    final id = "AUD_${DateTime.now().millisecondsSinceEpoch}";
    final now = DateTime.now().millisecondsSinceEpoch;
    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/$id.wav");
    await file.writeAsBytes(await wavFile.readAsBytes());

    final wavBytes = await file.readAsBytes();
    final rawPcmBytes = _extractPcmFromWav(wavBytes);
    final pcmBytes = _enhanceRecordedTxPcm(rawPcmBytes);
    final codec2Bytes =
    await _codec2Encode(pcmBytes);
    if (codec2Bytes.isEmpty) {
      _log("transmitAudioFile codec2 encode failed/empty");
      return;
    }
    _log("transmitAudioFile id=$id wav=${wavBytes.length} pcm=${pcmBytes.length} codec2=${codec2Bytes.length}");

    await DatabaseService.insertMessage({
      "id": id,
      "text": file.path,
      "timestamp": now,
      "status": "pending",
      "fromUser": "ME",
      "isImage": 2,
      "retryCount": 0,
      "lastAttempt": 0
    });
    _loadMessagesFromDB();

    await _sendMediaChunks(
      id: id,
      bytes: codec2Bytes,
      chunkType: "AUDIO_CHUNK",
      doneType: "AUDIO_DONE",
    );
  }

  Uint8List _extractPcmFromWav(Uint8List wavBytes) {
    if (wavBytes.length <= 44) return Uint8List(0);

    if (ascii.decode(wavBytes.sublist(0, 4), allowInvalid: true) != "RIFF" ||
        ascii.decode(wavBytes.sublist(8, 12), allowInvalid: true) != "WAVE") {
      return Uint8List.sublistView(wavBytes, 44);
    }

    final bd = ByteData.sublistView(wavBytes);
    int offset = 12;

    while (offset + 8 <= wavBytes.length) {
      final chunkId =
          ascii.decode(wavBytes.sublist(offset, offset + 4), allowInvalid: true);
      final chunkSize = bd.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;

      if (chunkId == "data") {
        if (dataStart >= wavBytes.length) return Uint8List(0);
        final end = dataStart + chunkSize;
        if (end > wavBytes.length) {
          return Uint8List.sublistView(wavBytes, dataStart);
        }
        return Uint8List.sublistView(wavBytes, dataStart, end);
      }

      final next = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
      if (next <= offset) break;
      offset = next;
    }

    return Uint8List.sublistView(wavBytes, 44);
  }

  Uint8List _buildWavFromPcm(
    Uint8List pcmBytes, {
    int sampleRate = 8000,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcmBytes.length;
    final fileSize = 36 + dataSize;
    final out = BytesBuilder();

    void wStr(String s) => out.add(ascii.encode(s));
    void w16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
    void w32(int v) => out.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);

    wStr("RIFF");
    w32(fileSize);
    wStr("WAVE");
    wStr("fmt ");
    w32(16);
    w16(1);
    w16(channels);
    w32(sampleRate);
    w32(byteRate);
    w16(blockAlign);
    w16(bitsPerSample);
    wStr("data");
    w32(dataSize);
    out.add(pcmBytes);

    return out.toBytes();
  }
  
  Future<Uint8List> _codec2Encode(Uint8List pcmBytes) async {
    try {
      final encoded = await _codec2Channel.invokeMethod<Uint8List>(
        "encodePcm",
        {"pcm": pcmBytes},
      );
      return encoded ?? Uint8List(0);
    } catch (e) {
      _log("codec2 encode error: $e");
      return Uint8List(0);
    }
  }

  Future<Uint8List> _codec2Decode(Uint8List codec2Bytes) async {
    try {
      final decoded = await _codec2Channel.invokeMethod<Uint8List>(
        "decodeCodec2",
        {"codec2": codec2Bytes},
      );
      return decoded ?? Uint8List(0);
    } catch (e) {
      _log("codec2 decode error: $e");
      return Uint8List(0);
    }
  }
 
  

  Future<void> _writeRawLine(String line) async {
    try {
      final parts = line.split("|");
      if (parts.length < 2) return;

      final domain = parts[0];
      final type = parts[1];

      if (domain == "T") {
        if (type == "ACK" || type == "CNAK") {
          final packetType = type == "ACK" ? _packetTextAck : _packetTextCnak;
          await _writeTransportPacket(
            _buildTransportPacket(
              type: packetType,
              header: _string8(parts[2]),
            ),
          );
          return;
        }
      } else if (domain == "A") {
        if (type == "CHUNK" && parts.length >= 7) {
          final id = parts[2];
          final seq = int.parse(parts[3]);
          final total = int.parse(parts[4]);
          final crc = int.parse(parts[5]);
          final payload = Uint8List.fromList(base64Decode(parts.sublist(6).join("|")));
          final header = BytesBuilder(copy: false)
            ..add(_string8(id))
            ..add(_u16Bytes(seq))
            ..add(_u16Bytes(total))
            ..add(_u32Bytes(crc));
          await _writeTransportPacket(
            _buildTransportPacket(
              type: _packetAudioChunk,
              header: header.takeBytes(),
              payload: payload,
            ),
          );
          return;
        }
        if (type == "DONE" && parts.length >= 5) {
          final header = BytesBuilder(copy: false)
            ..add(_string8(parts[2]))
            ..add(_u16Bytes(int.parse(parts[3])))
            ..add(_u32Bytes(int.parse(parts[4])));
          await _writeTransportPacket(
            _buildTransportPacket(type: _packetAudioDone, header: header.takeBytes()),
          );
          return;
        }
        if ((type == "CACK" || type == "CNAK") && parts.length >= 4) {
          final packetType = type == "CACK" ? _packetAudioCack : _packetAudioCnak;
          final header = BytesBuilder(copy: false)
            ..add(_string8(parts[2]))
            ..add(_u16Bytes(int.parse(parts[3])));
          await _writeTransportPacket(
            _buildTransportPacket(type: packetType, header: header.takeBytes()),
          );
          return;
        }
        if (type == "DACK" && parts.length >= 3) {
          await _writeTransportPacket(
            _buildTransportPacket(type: _packetAudioDack, header: _string8(parts[2])),
          );
          return;
        }
      }

      _log("writeRawLine unsupported binary mapping: $line");
    } catch (e) {
      _log("writeRawLine error: $e");
    }
  }

  Future<void> _sendMediaChunks({
    required String id,
    required List<int> bytes,
    required String chunkType,
    required String doneType,
  }) async {
    if (targetChar == null) {
      _log("sendMediaChunks skipped: targetChar null id=$id");
      return;
    }

    const int chunkSize = 60;

    const int maxChunkRetry = 5;
    final total = (bytes.length / chunkSize).ceil();
    _log("sendMediaChunks start id=$id type=$chunkType done=$doneType bytes=${bytes.length} total=$total");
    _isSendingMedia = true;
    _clearAckStateForId(id);
    _mediaCache[id] = bytes;
    _mediaChunkSize[id] = chunkSize;
    _mediaTotalChunks[id] = total;
    _mediaChunkType[id] = chunkType;

    try {
      for (int i = 0; i < total; i++) {
        int start = i * chunkSize;
        int end = start + chunkSize;
        if (end > bytes.length) end = bytes.length;
        final chunk = bytes.sublist(start, end);

        bool chunkDelivered = false;
        for (int attempt = 1;
     attempt <= maxChunkRetry;
     attempt++) {

  final key = "$id:$i";

  /// ✅ EARLY ACK CHECK FIRST
  if (_earlyChunkAcks.remove(key)) {
    _log("early ack consumed id=$id seq=$i");
    chunkDelivered = true;
    break;
  }

  /// ✅ ONLY ONE CHUNK AT A TIME
  while (_chunkInFlight) {
    await Future.delayed(
        const Duration(milliseconds: 10));
  }

  _chunkInFlight = true;

  final completer = Completer<void>();
  _chunkAckWaiters[key] = completer;

  final chunkCrc = _crc32(chunk);
  await _writeRawLine("A|CHUNK|$id|$i|$total|$chunkCrc|${base64Encode(chunk)}");

  try {
    await completer.future
        .timeout(const Duration(seconds: 3));

    chunkDelivered = true;

    _log(
      "chunk ack id=$id seq=$i attempt=$attempt"
    );

    break;

  } catch (_) {

    _log(
      "chunk timeout id=$id seq=$i attempt=$attempt"
    );

  } finally {

    _chunkInFlight = false;

    if (_chunkAckWaiters[key] ==
        completer) {
      _chunkAckWaiters.remove(key);
    }
  }
}

        if (!chunkDelivered) {
          _log("chunk delivery failed id=$id seq=$i");
          await DatabaseService.updateStatus(id, "failed");
          _loadMessagesFromDB();
          _clearAckStateForId(id);
          _mediaCache.remove(id);
          _mediaChunkSize.remove(id);
          _mediaTotalChunks.remove(id);
          _mediaChunkType.remove(id);
          return;
        }

        await Future.delayed(const Duration(milliseconds: 40));
      }

      final doneCompleter = Completer<void>();
      _doneAckWaiters[id] = doneCompleter;
      final mediaCrc = _crc32(bytes);
      await _writeRawLine("A|DONE|$id|$total|$mediaCrc");

      try {
        await doneCompleter.future.timeout(const Duration(seconds: 6));
        _log("done ack id=$id");
        await DatabaseService.updateStatus(id, "delivered");
      } catch (_) {
        _log("done ack timeout id=$id");
        _clearAckStateForId(id);
        _mediaCache.remove(id);
        _mediaChunkSize.remove(id);
        _mediaTotalChunks.remove(id);
        _mediaChunkType.remove(id);
      } finally {
        if (_doneAckWaiters[id] == doneCompleter) {
          _doneAckWaiters.remove(id);
        }
      }
      _loadMessagesFromDB();
    } finally {
      _log("sendMediaChunks end id=$id");
      _isSendingMedia = false;
    }
  }

  
  // ===============================
  // RETRY ENGINE
  // ===============================
    void _startRetryEngine() {
  _retryTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {

    if (targetChar == null || !isReady) return;
    if (_isSendingMedia || _isSendingText || _isRecordingAudio || _hasRemoteActiveTransfer) return;

    final pending = await DatabaseService.getPendingMessages();
    if (pending.isEmpty) return;

    final msg = pending.first;

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastAttempt = msg["lastAttempt"] ?? 0;
    final retryCount = msg["retryCount"] ?? 0;

    // Stop retrying after 5 attempts
    if (retryCount >= 5) {
      await DatabaseService.updateStatus(msg["id"], "failed");
      _loadMessagesFromDB();
      return;
    }

    // Wait 6 seconds before next retry
    if (now - lastAttempt < 6000) return;

    _log("retry attempt=${retryCount + 1} id=${msg["id"]} type=${msg["isImage"]}");

    if (msg["isImage"] == 1) {
      await resendImage(msg["id"], msg["text"]);
    } else if (msg["isImage"] == 2) {
      await resendAudio(msg["id"], msg["text"]);
    } else {
      await resendText(msg["id"], msg["text"], msg["timestamp"]);
    }

    await DatabaseService.markAttempt(msg["id"]);

    _loadMessagesFromDB();
  });
}
Future<void> resendText(String id, String text, int timestamp) async {
  _log("resendText id=$id");
  await _sendTextSession(
    id: id,
    timestamp: timestamp,
    text: text,
  );
}
Future<void> resendImage(String id, String path) async {
  _log("resendImage id=$id path=$path");

  final file = File(path);
  if (!file.existsSync()) return;

  final bytes = await file.readAsBytes();
  final dot = path.lastIndexOf('.');
  final extension =
      (dot >= 0 && dot + 1 < path.length) ? path.substring(dot + 1).toLowerCase() : "bin";
  try {
    await _sendImageChunks(
      id: id,
      bytes: bytes,
      extension: extension,
    );
  } catch (_) {
    _log("resendImage failed id=$id");
    await DatabaseService.updateStatus(id, "failed");
    _loadMessagesFromDB();
  } finally {
    _loadMessagesFromDB();
  }
}

  Future<void> resendAudio(String id, String path) async {
  _log("resendAudio id=$id path=$path");
  final file = File(path);
  if (!file.existsSync()) return;

  final wavBytes = await file.readAsBytes();
  final rawPcmBytes = _extractPcmFromWav(wavBytes);
  final pcmBytes = _enhanceRecordedTxPcm(rawPcmBytes);
  final bytes = await _codec2Encode(pcmBytes);
  if (bytes.isEmpty) {
    _log("resendAudio failed id=$id codec2 empty");
    return;
  }
  await _sendMediaChunks(
    id: id,
    bytes: bytes,
    chunkType: "AUDIO_CHUNK",
    doneType: "AUDIO_DONE",
  );
}

  void _startImageCleanupEngine() {
    _imageCleanupTimer =
        Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final staleAudioIds = _audioLastSeenMs.entries
          .where((e) => now - e.value > 30000)
          .map((e) => e.key)
          .toList();

      for (final id in staleAudioIds) {
        audioBuffer.remove(id);
        audioTotal.remove(id);
        _audioLastSeenMs.remove(id);
      }
      if (staleAudioIds.isNotEmpty) {
        _log("cleanup stale audio ids=${staleAudioIds.length}");
      }

      final staleImageIds = _imageLastSeenMs.entries
          .where((e) => now - e.value > 30000)
          .map((e) => e.key)
          .toList();

      for (final id in staleImageIds) {
        _imageBuffer.remove(id);
        _imageTotal.remove(id);
        _imageExtension.remove(id);
        _imageExpectedCrc.remove(id);
        _imageMissingBatchCursor.remove(id);
        _imageLastSeenMs.remove(id);
        _cnakRetryCount.remove(id);
        _cnakLastMs.remove(id);
        if (_activeIncomingImageId == id) {
          _activeIncomingImageId = null;
        }
      }
      if (staleImageIds.isNotEmpty) {
        _log("cleanup stale image ids=${staleImageIds.length}");
      }
    });
  }

  Future<void> _onImageComplete(
    String id,
    List<int> fullBytes, {
    String extension = "bin",
  }) async {
    _log("onImageComplete id=$id bytes=${fullBytes.length}");
    final alreadySaved = await DatabaseService.messageExists(id);
    if (alreadySaved) return;
    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/$id.$extension");
    await file.writeAsBytes(fullBytes);
    _log("image saved id=$id path=${file.path} bytes=${fullBytes.length}");

    await DatabaseService.insertMessage({
      "id": id,
      "text": file.path,
      "timestamp": DateTime.now().millisecondsSinceEpoch,
      "status": "delivered",
      "fromUser": "REMOTE",
      "isImage": 1
    });

    await _notifyIncoming("Image received");

    _loadMessagesFromDB();
  }

  Future<void> _handleIncomingBleRealtimePacket(Uint8List packet) async {
    if (packet.length < _bleRealtimeHeaderBytes || packet[0] != _bleRealtimeMagic) return;

    final packetType = packet[1];
    final sequence = packet[2] | (packet[3] << 8);
    final payloadLength = packet[4];
    final headerSize = packet[5];
    final version = packet[6];
    final flags = packet[7];
    if (headerSize != _bleRealtimeHeaderSizeField || version != _bleRealtimeVersion) {
      _log("drop realtime packet invalid header size=$headerSize version=$version");
      return;
    }
    final availablePayload = packet.length - _bleRealtimeHeaderBytes;
    final effectiveLength =
        payloadLength < availablePayload ? payloadLength : availablePayload;

    if (packetType == _BleRealtimePacketType.start.code) {
      _log("realtime BLE START seq=$sequence");
      if (_incomingRealtimeAudioId != null &&
          _incomingRealtimeAudioPcmBuffer.isNotEmpty) {
        await _finalizeIncomingRealtimeAudioSession();
      }
      final id = "AUD_${DateTime.now().millisecondsSinceEpoch}";
      _incomingRealtimeAudioId = id;
      _incomingRealtimeAudioPcmBuffer.clear();
      _setRemoteTransferLock(_TransferSessionType.realtimeAudio, id);
      await _startRealtimePlayback();
      return;
    }

    if (packetType == _BleRealtimePacketType.stop.code) {
      _log("realtime BLE STOP seq=$sequence");
      await _finalizeIncomingRealtimeAudioSession();
      _clearRemoteTransferLock(type: _TransferSessionType.realtimeAudio);
      await _stopRealtimePlayback();
      return;
    }

    if (packetType != _BleRealtimePacketType.audio.code || effectiveLength <= 0) {
      return;
    }

    final payload = Uint8List.sublistView(
      packet,
      _bleRealtimeHeaderBytes,
      _bleRealtimeHeaderBytes + effectiveLength,
    );
    _log(
      "realtime BLE AUDIO seq=$sequence bytes=$effectiveLength final=${(flags & 0x01) != 0 ? 1 : 0}",
    );
    if (_incomingRealtimeAudioId == null) {
      _incomingRealtimeAudioId = "AUD_${DateTime.now().millisecondsSinceEpoch}";
      _setRemoteTransferLock(
        _TransferSessionType.realtimeAudio,
        _incomingRealtimeAudioId!,
      );
    }
    _incomingRealtimeAudioPcmBuffer.addAll(payload);
    await _playRealtimePcm(payload);
    if ((flags & 0x01) != 0) {
      await _finalizeIncomingRealtimeAudioSession();
      await _stopRealtimePlayback();
    }
  }

  Future<void> _onNotifyData(List<int> data) async {
    _log("notify bytes=${data.length}");

    if (data.isNotEmpty && data[0] == _bleRealtimeMagic) {
      await _handleIncomingBleRealtimePacket(Uint8List.fromList(data));
      return;
    }

    _incomingPacketBuffer.addAll(data);

    while (true) {
      if (_incomingPacketBuffer.length < _transportPrefixBytes) {
        break;
      }

      if (_incomingPacketBuffer[0] != _transportMagicLo ||
          _incomingPacketBuffer[1] != _transportMagicHi) {
        _incomingPacketBuffer.removeAt(0);
        continue;
      }

      final headerLen = _incomingPacketBuffer[4];
      final payloadLen = _incomingPacketBuffer[5] | (_incomingPacketBuffer[6] << 8);
      final totalLen = _transportPrefixBytes + headerLen + payloadLen;
      if (totalLen > 8192) {
        _log("dropping oversized transport packet total=$totalLen");
        _incomingPacketBuffer.clear();
        break;
      }
      if (_incomingPacketBuffer.length < totalLen) {
        break;
      }

      final packetBytes = Uint8List.fromList(_incomingPacketBuffer.sublist(0, totalLen));
      _incomingPacketBuffer.removeRange(0, totalLen);
      final packet = _decodeTransportPacket(packetBytes);
      if (packet == null) {
        continue;
      }
      await _dispatchTransportPacket(packet);
    }
  }

  Future<void> _handleImageStartBinary({
    required String id,
    required int total,
    required String extension,
  }) async {
    if (id.isEmpty || total <= 0) return;
    _setRemoteTransferLock(_TransferSessionType.image, id);
    _markImageActivity("recv_img_start");
    _activeIncomingImageId = id;
    final existing = _imageBuffer[id];
    final isDuplicateStart = existing != null && _imageTotal[id] == total;
    if (!isDuplicateStart) {
      _imageBuffer[id] = List.generate(total, (_) => Uint8List(0));
      _imageTotal[id] = total;
      _imageExtension[id] = extension.isEmpty ? "bin" : extension;
      _imageExpectedCrc.remove(id);
      _imageMissingBatchCursor[id] = 0;
      _cnakRetryCount.remove(id);
      _cnakLastMs.remove(id);
    } else {
      _log("IMG_START duplicate id=$id total=$total preserving partial image state");
    }
    _imageLastSeenMs[id] = DateTime.now().millisecondsSinceEpoch;
    await _sendImageStartAckPacket(id);
    _log("IMG_START id=$id total=$total ext=$extension");
  }

  Future<void> _handleImageChunkBinary({
    required String id,
    required int seq,
    required int total,
    required int expectedCrc,
    required Uint8List payload,
  }) async {
    if (id.isEmpty || total <= 0 || seq < 0 || seq >= total) return;
    final actualCrc = _crc32(payload);
    if (actualCrc != expectedCrc) {
      await _sendImageCnakPacket(id: id, seq: seq);
      _log("img chunk crc mismatch id=$id seq=$seq expected=$expectedCrc actual=$actualCrc");
      return;
    }

    final alreadySaved = await DatabaseService.messageExists(id);
    if (alreadySaved) {
      await _sendImageCackPacket(id: id, seq: seq);
      return;
    }

    _imageBuffer.putIfAbsent(id, () => List.generate(total, (_) => Uint8List(0)));
    if (_imageBuffer[id]!.length != total) {
      _imageBuffer[id] = List.generate(total, (_) => Uint8List(0));
    }
    _imageTotal[id] = total;
    _imageLastSeenMs[id] = DateTime.now().millisecondsSinceEpoch;

    if (_imageBuffer[id]![seq].isEmpty) {
      _imageBuffer[id]![seq] = Uint8List.fromList(payload);
    }
    if (_imageExpectedCrc.containsKey(id)) {
      await _tryFinalizeIncomingImage(id);
    }
  }

  Future<void> _handleImageDoneBinary({
    required String id,
    required int total,
    required int expectedCrc,
  }) async {
    if (id.isEmpty || total <= 0) return;
    if (!_imageBuffer.containsKey(id) || _imageBuffer[id]!.length != total) {
      return;
    }
    _imageExpectedCrc[id] = expectedCrc;
    await _tryFinalizeIncomingImage(id);
  }

  Future<void> _handleImageAckBinary({
    required String id,
    required int seq,
  }) async {
    final key = "$id:$seq";
    final waiter = _chunkAckWaiters[key];

    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      _log("img cack matched id=$id seq=$seq");
    } else {
      _earlyChunkAcks.add(key);
      _log("img early cack stored id=$id seq=$seq");
    }
  }

  Future<void> _handleImageCnakBinary({
    required String id,
    required int seq,
  }) async {
    final chunks = _txImageChunks[id];
    if (chunks == null || seq < 0 || seq >= chunks.length) return;
    await _sendImageChunkPacket(
      id: id,
      seq: seq,
      total: chunks.length,
      chunk: chunks[seq],
    );
    _log("img cnak resend id=$id seq=$seq");
  }

  Future<void> _handleImageDackBinary(String id) async {
    final waiter = _doneAckWaiters[id];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      _log("img dack matched id=$id");
    }
    _txImageChunks.remove(id);
    _mediaChunkSize.remove(id);
    _mediaTotalChunks.remove(id);
    _mediaChunkType.remove(id);
  }

  Future<void> _handleImageStartAckBinary(String id) async {
    final waiter = _imageStartAckWaiters[id];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      _log("img start ack matched id=$id");
    }
  }

  Future<void> _handleImageMissingBatchBinary(
    String id,
    List<int> seqs,
  ) async {
    final chunks = _txImageChunks[id];
    if (chunks == null || seqs.isEmpty) return;
    for (final seq in seqs) {
      if (seq < 0 || seq >= chunks.length) continue;
      await _sendImageChunkPacket(
        id: id,
        seq: seq,
        total: chunks.length,
        chunk: chunks[seq],
      );
      await Future.delayed(const Duration(milliseconds: 70));
    }
    _log("img missing batch resend id=$id count=${seqs.length}");
  }

  Future<void> _handleImagePipePacket(String line) async {
    _log("legacy string image packet ignored: $line");
  }

 

  // ===============================
  // LOAD FROM DATABASE
  // ===============================

 Future<void> _loadMessagesFromDB() async {
  final data = await DatabaseService.getAllMessages();
  _log("loadMessages count=${data.length}");

  if (!mounted) return;

  setState(() {
    chatMessages.clear();

    for (var msg in data) {

      final mediaType = msg["isImage"] ?? 0;
      final bool isImage = mediaType == 1;
      final bool isAudio = mediaType == 2;

      chatMessages.add(
        GestureDetector(
          onLongPress: () => _confirmDelete(msg["id"]),
          child: MessageBubble(
            content: msg["text"],     // ✅ changed from text:
            isImage: isImage,
            isAudio: isAudio,
            isMe: msg["fromUser"] == "ME",
            time: DateTime.fromMillisecondsSinceEpoch(msg["timestamp"]),
            status: msg["status"],
          ),
        ),
      );
    }
  });

  Future.delayed(const Duration(milliseconds: 200), () {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  });
}

 

  // ===============================
  // DELETE MESSAGE
  // ===============================

  void _confirmDelete(String id) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Message"),
        content: const Text(
            "This message will be permanently deleted and cannot be recovered."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel")),
          TextButton(
              onPressed: () async {
                await DatabaseService.deleteMessage(id);
                Navigator.pop(context);
                _loadMessagesFromDB();
              },
              child: const Text("Delete")),
        ],
      ),
    );
  }

  // ===============================
  // BLE CONNECTION
  // ===============================

  Future<void> _initConnection() async {
    _log("initConnection start device=${widget.device.remoteId.str}");
    _connectionSubscription =
        widget.device.connectionState.listen((state) {
      _log("connectionState=$state hasChar=${targetChar != null}");
      if (mounted) {
        setState(() =>
            isReady = (state == BluetoothConnectionState.connected &&
                targetChar != null));
      }
    });

    try {
      await widget.device.connect(autoConnect: false).catchError((_) {});
      _log("device connect attempted");
      await widget.device.requestMtu(247);
      _log("mtu requested 247");
      

      List<BluetoothService> services =
          await widget.device.discoverServices();

      for (var service in services) {
        if (service.uuid.toString().toLowerCase() ==
            "12345678-1234-1234-1234-1234567890ab") {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() ==
                "abcd1234-5678-1234-5678-abcdef123456") {

              targetChar = char;
              await char.setNotifyValue(true);

              _notifySubscription =
                  char.onValueReceived.listen((data) async {
                await _onNotifyData(data);
              });

              if (mounted) setState(() => isReady = true);
              _log("target characteristic ready uuid=${char.uuid}");
            }
          }
        }
      }
    } catch (e) {
      _log("connection error: $e");
    }
  }

  // ===============================
  // SEND MESSAGE
  // ===============================

  Future<void> sendMessage() async {

    if (!_canStartTransfer || controller.text.trim().isEmpty) {
      _log(
        "sendMessage skipped "
        "hasChar=${targetChar != null} empty=${controller.text.trim().isEmpty} "
        "remoteLocked=$_hasRemoteActiveTransfer canStart=$_canStartTransfer",
      );
      return;
    }

    final trimmed = controller.text.trim();
    controller.clear();

    String id =
        "${DateTime.now().millisecondsSinceEpoch}_${widget.device.remoteId.str}";

   


    final message = {
      "type": "MSG",
      "id": id,
      "text": trimmed,
      
      "ts": DateTime.now().millisecondsSinceEpoch
    };

    await DatabaseService.insertMessage({
      "id": id,
      "text": trimmed,
      
      "timestamp": message["ts"],
      "status": "pending",
      "fromUser": "ME"
    });

    await _sendTextSession(
      id: id,
      timestamp: message["ts"] as int,
      text: trimmed,
    );
    _log("sendMessage id=$id textLen=${trimmed.length}");

    _loadMessagesFromDB();
}
  // ===============================
  // UI
  // ===============================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.device.platformName),
            Text(
              isReady ? "Ready to Transmit" : "Syncing...",
              style: TextStyle(
                fontSize: 12,
                color: isReady ? Colors.green : Colors.red,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 20),
              itemCount: chatMessages.length,
              itemBuilder: (context, index) =>
                  chatMessages[index],
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final transferLocked = _hasRemoteActiveTransfer;
    final canUseInputs = _canStartTransfer;
    final canToggleRecording = _isRecordingAudio || canUseInputs;
    final lockHint = transferLocked
        ? "Remote ${_transferSessionLabel(_remoteActiveTransferType!)} in progress"
        : null;
    final micButtonColor = (!canToggleRecording && !_isRecordingAudio)
        ? Colors.grey
        : (_isRecordingAudio ? const Color(0xFFE53935) : const Color(0xFF1FA855));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border:
            Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        child: Row(
          children: [
              IconButton(
                icon: const Icon(Icons.image),
               onPressed: canUseInputs ? pickImage : null,
              ),
              GestureDetector(
                onTap: canToggleRecording ? _openRealtimeAudioPage : null,
                child: Container(
                  width: 52,
                  height: 52,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: micButtonColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: micButtonColor.withOpacity(0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.mic,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !transferLocked && !_isRecordingAudio && !_isSendingMedia,
                decoration: InputDecoration(
                  hintText: lockHint ?? "Enter Radio Message...",
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(25),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor:
                  canUseInputs ? Colors.blue : Colors.grey,
              child: IconButton(
                icon: const Icon(Icons.send,
                    color: Colors.white),
                onPressed: canUseInputs ? sendMessage : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final String content;      // text OR image path
  final bool isImage;
  final bool isAudio;
  final bool isMe;
  final DateTime time;
  final String status;

  const MessageBubble({
    required this.content,
    required this.isImage,
    required this.isAudio,
    required this.isMe,
    required this.time,
    required this.status,
    super.key,
  });

  @override
  Widget build(BuildContext context) {

    Widget messageWidget;

    if (isImage) {
      final lower = content.toLowerCase();
      messageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: () {
            final state =
                context.findAncestorStateOfType<_ChatScreenState>();

            if (state == null) return;

            final images = state._getAllChatImages();
            final index = images.indexOf(content);

            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FullscreenImageView(
                  images: images,
                  initialIndex: index,
                ),
              ),
            );
          },
          child: lower.endsWith('.avif')
              ? AvifImage.file(
                  File(content),
                  width: 200,
                  fit: BoxFit.cover,
                )
              : Image.file(
                  File(content),
                  width: 200,
                  fit: BoxFit.cover,
                ),
        ),
      );
    } else if (isAudio) {
      messageWidget = AudioMessagePlayer(
        path: content,
        isMe: isMe,
      );
    } else {
      messageWidget = Text(
        content,
        style: TextStyle(
          color: isMe ? Colors.white : Colors.black87,
        ),
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: UnconstrainedBox(
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isMe ? Colors.blue : Colors.grey.shade300,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 0),
              bottomRight: Radius.circular(isMe ? 0 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              messageWidget,
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "🕒 ${time.hour}:${time.minute.toString().padLeft(2, '0')}",
                    style: TextStyle(
                      fontSize: 11,
                      color: isMe ? Colors.white70 : Colors.black54,
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      status == "pending"
                          ? Icons.access_time
                          : status == "failed"
                              ? Icons.error
                              : Icons.done_all,
                      size: 14,
                      color: status == "pending"
                          ? Colors.white70
                          : status == "failed"
                              ? Colors.redAccent
                              : Colors.lightBlueAccent,
                    ),
                  ]
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AudioMessagePlayer extends StatefulWidget {
  final String path;
  final bool isMe;

  const AudioMessagePlayer({
    required this.path,
    required this.isMe,
    super.key,
  });

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  late final AudioPlayer _player;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

    _durationSub = _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });

    _positionSub = _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });

    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      final playing = state == PlayerState.playing;
      setState(() => _isPlaying = playing);
      if (state == PlayerState.completed) {
        setState(() => _position = Duration.zero);
      }
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }
    if (_position > Duration.zero && _position < _duration) {
      await _player.resume();
    } else {
      await _player.play(DeviceFileSource(widget.path));
    }
  }

  String _format(Duration d) {
    final totalSeconds = d.inSeconds;
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isMe ? Colors.white : Colors.black87;
    final maxMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, maxMs == 0 ? 1 : maxMs);
    final progress = maxMs == 0 ? 0.0 : posMs / maxMs;

    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: _togglePlay,
                child: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: color,
                  size: 30,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _isPlaying ? "Playing" : "Audio Message",
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor:
                widget.isMe ? Colors.white24 : Colors.black12,
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.isMe ? Colors.white : Colors.blue,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "${_format(_position)} / ${_format(_duration)}",
            style: TextStyle(
              color: widget.isMe ? Colors.white70 : Colors.black54,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompressedImageResult {
  final Uint8List bytes;
  final String extension;

  const _CompressedImageResult({
    required this.bytes,
    required this.extension,
  });
}

class _TextTxCacheEntry {
  final int timestamp;
  final String text;
  final int crc;

  const _TextTxCacheEntry({
    required this.timestamp,
    required this.text,
    required this.crc,
  });
}

class FullscreenImageView extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const FullscreenImageView({
    required this.images,
    required this.initialIndex,
    super.key,
  });

  @override
  State<FullscreenImageView> createState() =>
      _FullscreenImageViewState();
}

class _FullscreenImageViewState
    extends State<FullscreenImageView> {

  late PageController _controller;
  late int currentIndex;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _controller =
        PageController(initialPage: currentIndex);
  }

  Widget _buildImage(String path) {
    final lower = path.toLowerCase();

    final imageWidget = lower.endsWith('.avif')
        ? AvifImage.file(File(path))
        : Image.file(File(path));

    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(child: imageWidget),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          "${currentIndex + 1}/${widget.images.length}",
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        onPageChanged: (i) {
          setState(() => currentIndex = i);
        },
        itemBuilder: (context, index) {
          return _buildImage(
              widget.images[index]);
        },
      ),
    );
  }
}

