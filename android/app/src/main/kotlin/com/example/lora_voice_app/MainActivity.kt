package com.example.lora_voice_app

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfInt
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import org.opencv.photo.Photo

class MainActivity : FlutterActivity() {
    // Realtime gain is handled in Dart before playPcm to avoid double amplification.
    private val realtimeGain = 1.0f
    private val backgroundGuardChannel = "com.example.lora_voice_app/background_guard"

    companion object {
        private var openCvReady: Boolean = false

        init {
            System.loadLibrary("codec2bridge")
        }
    }

    private external fun nativeEncodePcm(pcmBytes: ByteArray): ByteArray
    private external fun nativeDecodeCodec2(codec2Bytes: ByteArray): ByteArray
    private var realtimeTrack: AudioTrack? = null

    private fun startRealtimePlayback() {
        if (realtimeTrack != null) return

        val sampleRate = 8000
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        realtimeTrack = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            minBuffer.coerceAtLeast(2048),
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
        realtimeTrack?.play()
    }

    private fun playPcm(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        if (realtimeTrack == null) {
            startRealtimePlayback()
        }
        val boosted = boostPcm16Le(pcm, realtimeGain)
        realtimeTrack?.write(boosted, 0, boosted.size)
    }

    private fun boostPcm16Le(pcm: ByteArray, gain: Float): ByteArray {
        if (pcm.isEmpty()) return pcm
        val out = ByteArray(pcm.size)
        var i = 0
        while (i + 1 < pcm.size) {
            val lo = pcm[i].toInt() and 0xFF
            val hi = pcm[i + 1].toInt()
            val sample = ((hi shl 8) or lo).toShort().toInt()

            val amplified = (sample * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            out[i] = (amplified and 0xFF).toByte()
            out[i + 1] = ((amplified shr 8) and 0xFF).toByte()
            i += 2
        }
        return out
    }

    private fun stopRealtimePlayback() {
        realtimeTrack?.stop()
        realtimeTrack?.release()
        realtimeTrack = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        openCvReady = OpenCVLoader.initDebug()
    }

    private fun startBackgroundGuard() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val intent = BackgroundGuardService.startIntent(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopBackgroundGuard() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        stopService(BackgroundGuardService.stopIntent(this))
    }

    private fun resizeKeepAspect(src: Mat, maxDimension: Int): Mat {
        val width = src.width()
        val height = src.height()
        if (width <= maxDimension && height <= maxDimension) {
            return src.clone()
        }

        val scale = if (width > height) {
            maxDimension.toDouble() / width.toDouble()
        } else {
            maxDimension.toDouble() / height.toDouble()
        }

        val newW = (width * scale).toInt().coerceAtLeast(1)
        val newH = (height * scale).toInt().coerceAtLeast(1)

        val dst = Mat()
        Imgproc.resize(src, dst, Size(newW.toDouble(), newH.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        return dst
    }

    private fun denoiseImage(src: Mat): Mat {
        val denoised = Mat()
        Photo.fastNlMeansDenoisingColored(src, denoised, 5f, 5f, 7, 21)
        return denoised
    }

    private fun encodeImage(src: Mat, format: String, quality: Int): ByteArray? {
        val ext: String
        val params: MatOfInt
        when (format.uppercase()) {
            "JPG", "JPEG" -> {
                ext = ".jpg"
                params = MatOfInt(Imgcodecs.IMWRITE_JPEG_QUALITY, quality)
            }
            else -> {
                ext = ".webp"
                params = MatOfInt(Imgcodecs.IMWRITE_WEBP_QUALITY, quality)
            }
        }

        val out = MatOfByte()
        val ok = Imgcodecs.imencode(ext, src, out, params)
        params.release()
        if (!ok) {
            out.release()
            return null
        }

        val bytes = out.toArray()
        out.release()
        return bytes
    }

    private fun compressImageCv2(
        src: Mat,
        maxDimension: Int,
        targetSizeKb: Int,
        minQuality: Int,
        maxQuality: Int,
        format: String,
    ): ByteArray {
        if (src.empty()) {
            return ByteArray(0)
        }

        val resized = resizeKeepAspect(src, maxDimension)
        val denoised = denoiseImage(resized)
        resized.release()

        var low = minQuality
        var high = maxQuality
        var best = encodeImage(denoised, format, minQuality) ?: ByteArray(0)

        while (low <= high) {
            val mid = (low + high) / 2
            val attempt = encodeImage(denoised, format, mid) ?: ByteArray(0)
            val sizeKb = attempt.size / 1024.0
            if (sizeKb <= targetSizeKb) {
                best = attempt
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        denoised.release()
        return best
    }

    private fun compressImageCv2FromPath(
        path: String,
        maxDimension: Int,
        targetSizeKb: Int,
        minQuality: Int,
        maxQuality: Int,
        format: String,
    ): ByteArray {
        val src = Imgcodecs.imread(path, Imgcodecs.IMREAD_COLOR)
        if (src.empty()) {
            src.release()
            return ByteArray(0)
        }
        val bytes = compressImageCv2(src, maxDimension, targetSizeKb, minQuality, maxQuality, format)
        src.release()
        return bytes
    }

    private fun compressImageCv2FromBytes(
        inputBytes: ByteArray,
        maxDimension: Int,
        targetSizeKb: Int,
        minQuality: Int,
        maxQuality: Int,
        format: String,
    ): ByteArray {
        val inMat = MatOfByte(*inputBytes)
        val src = Imgcodecs.imdecode(inMat, Imgcodecs.IMREAD_COLOR)
        inMat.release()
        if (src.empty()) {
            src.release()
            return ByteArray(0)
        }
        val bytes = compressImageCv2(src, maxDimension, targetSizeKb, minQuality, maxQuality, format)
        src.release()
        return bytes
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.lora_voice_app/codec2"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "encodePcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm == null) {
                        result.error("BAD_ARGS", "pcm is required", null)
                    } else {
                        result.success(nativeEncodePcm(pcm))
                    }
                }
                "decodeCodec2" -> {
                    val codec2 = call.argument<ByteArray>("codec2")
                    if (codec2 == null) {
                        result.error("BAD_ARGS", "codec2 is required", null)
                    } else {
                        result.success(nativeDecodeCodec2(codec2))
                    }
                }
                "startRealtimePlayback" -> {
                    startRealtimePlayback()
                    result.success(null)
                }
                "playPcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm == null) {
                        result.error("BAD_ARGS", "pcm is required", null)
                    } else {
                        playPcm(pcm)
                        result.success(null)
                    }
                }
                "stopRealtimePlayback" -> {
                    stopRealtimePlayback()
                    result.success(null)
                }
                "compressImageCv2" -> {
                    if (!openCvReady) {
                        result.error("CV2_INIT", "OpenCV failed to initialize", null)
                        return@setMethodCallHandler
                    }

                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("BAD_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }

                    val maxDimension = call.argument<Int>("maxDimension") ?: 1280
                    val targetSizeKb = call.argument<Int>("targetSizeKb") ?: 40
                    val minQuality = call.argument<Int>("minQuality") ?: 20
                    val maxQuality = call.argument<Int>("maxQuality") ?: 80
                    val format = call.argument<String>("format") ?: "WEBP"

                    val bytes = compressImageCv2FromPath(
                        path = path,
                        maxDimension = maxDimension,
                        targetSizeKb = targetSizeKb,
                        minQuality = minQuality,
                        maxQuality = maxQuality,
                        format = format,
                    )
                    if (bytes.isEmpty()) {
                        result.error("CV2_COMPRESS", "Image compression failed", null)
                    } else {
                        result.success(mapOf("bytes" to bytes, "format" to format.uppercase()))
                    }
                }
                "compressImageBytesCv2" -> {
                    if (!openCvReady) {
                        result.error("CV2_INIT", "OpenCV failed to initialize", null)
                        return@setMethodCallHandler
                    }

                    val imageBytes = call.argument<ByteArray>("bytes")
                    if (imageBytes == null || imageBytes.isEmpty()) {
                        result.error("BAD_ARGS", "bytes is required", null)
                        return@setMethodCallHandler
                    }

                    val maxDimension = call.argument<Int>("maxDimension") ?: 1280
                    val targetSizeKb = call.argument<Int>("targetSizeKb") ?: 40
                    val minQuality = call.argument<Int>("minQuality") ?: 20
                    val maxQuality = call.argument<Int>("maxQuality") ?: 80
                    val format = call.argument<String>("format") ?: "WEBP"

                    val bytes = compressImageCv2FromBytes(
                        inputBytes = imageBytes,
                        maxDimension = maxDimension,
                        targetSizeKb = targetSizeKb,
                        minQuality = minQuality,
                        maxQuality = maxQuality,
                        format = format,
                    )
                    if (bytes.isEmpty()) {
                        result.error("CV2_COMPRESS", "Image compression failed", null)
                    } else {
                        result.success(mapOf("bytes" to bytes, "format" to format.uppercase()))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            backgroundGuardChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startGuard" -> {
                    startBackgroundGuard()
                    result.success(null)
                }
                "stopGuard" -> {
                    stopBackgroundGuard()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        stopBackgroundGuard()
        stopRealtimePlayback()
        super.onDestroy()
    }
}
