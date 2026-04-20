#include <jni.h>
#include <vector>
#include <cstdint>

extern "C" {
struct CODEC2;
CODEC2 *codec2_create(int mode);
void codec2_destroy(CODEC2 *codec2_state);
void codec2_encode(CODEC2 *codec2_state, unsigned char bytes[], short speech_in[]);
void codec2_decode(CODEC2 *codec2_state, short speech_out[], const unsigned char bytes[]);
int codec2_samples_per_frame(CODEC2 *codec2_state);
int codec2_bytes_per_frame(CODEC2 *codec2_state);
}

// Good tradeoff mode for bandwidth.
static constexpr int CODEC2_MODE_1300 = 4;

static std::vector<int16_t> pcmBytesToI16(const jbyte *data, jsize size) {
    std::vector<int16_t> out;
    out.reserve(static_cast<size_t>(size / 2));
    for (jsize i = 0; i + 1 < size; i += 2) {
        uint16_t lo = static_cast<uint8_t>(data[i]);
        uint16_t hi = static_cast<uint8_t>(data[i + 1]);
        int16_t sample = static_cast<int16_t>((hi << 8) | lo);
        out.push_back(sample);
    }
    return out;
}

static std::vector<uint8_t> i16ToPcmBytes(const std::vector<int16_t> &samples) {
    std::vector<uint8_t> out;
    out.reserve(samples.size() * 2);
    for (int16_t s : samples) {
        out.push_back(static_cast<uint8_t>(s & 0xff));
        out.push_back(static_cast<uint8_t>((s >> 8) & 0xff));
    }
    return out;
}

extern "C"
JNIEXPORT jbyteArray JNICALL
Java_com_example_lora_1voice_1app_MainActivity_nativeEncodePcm(
        JNIEnv *env, jobject /*thiz*/, jbyteArray pcmBytes) {
    if (pcmBytes == nullptr) return env->NewByteArray(0);

    const jsize inSize = env->GetArrayLength(pcmBytes);
    std::vector<jbyte> inBuf(static_cast<size_t>(inSize));
    env->GetByteArrayRegion(pcmBytes, 0, inSize, inBuf.data());

    CODEC2 *c2 = codec2_create(CODEC2_MODE_1300);
    if (c2 == nullptr) return env->NewByteArray(0);

    const int spf = codec2_samples_per_frame(c2);
    const int bpf = codec2_bytes_per_frame(c2);

    auto samples = pcmBytesToI16(inBuf.data(), inSize);
    if (spf <= 0 || bpf <= 0 || samples.empty()) {
        codec2_destroy(c2);
        return env->NewByteArray(0);
    }

    const size_t frames = (samples.size() + spf - 1) / spf;
    samples.resize(frames * spf, 0);

    std::vector<uint8_t> out(frames * static_cast<size_t>(bpf));
    for (size_t f = 0; f < frames; f++) {
        codec2_encode(
                c2,
                out.data() + (f * bpf),
                samples.data() + (f * spf));
    }
    codec2_destroy(c2);

    jbyteArray result = env->NewByteArray(static_cast<jsize>(out.size()));
    if (result != nullptr && !out.empty()) {
        env->SetByteArrayRegion(
                result, 0, static_cast<jsize>(out.size()),
                reinterpret_cast<const jbyte *>(out.data()));
    }
    return result;
}

extern "C"
JNIEXPORT jbyteArray JNICALL
Java_com_example_lora_1voice_1app_MainActivity_nativeDecodeCodec2(
        JNIEnv *env, jobject /*thiz*/, jbyteArray codec2Bytes) {
    if (codec2Bytes == nullptr) return env->NewByteArray(0);

    const jsize inSize = env->GetArrayLength(codec2Bytes);
    std::vector<jbyte> inBuf(static_cast<size_t>(inSize));
    env->GetByteArrayRegion(codec2Bytes, 0, inSize, inBuf.data());

    CODEC2 *c2 = codec2_create(CODEC2_MODE_1300);
    if (c2 == nullptr) return env->NewByteArray(0);

    const int spf = codec2_samples_per_frame(c2);
    const int bpf = codec2_bytes_per_frame(c2);

    if (spf <= 0 || bpf <= 0 || inSize < bpf) {
        codec2_destroy(c2);
        return env->NewByteArray(0);
    }

    const size_t frames = static_cast<size_t>(inSize / bpf);
    std::vector<int16_t> pcmOut(frames * static_cast<size_t>(spf));

    for (size_t f = 0; f < frames; f++) {
        codec2_decode(
                c2,
                pcmOut.data() + (f * spf),
                reinterpret_cast<const unsigned char *>(inBuf.data() + (f * bpf)));
    }
    codec2_destroy(c2);

    auto pcmBytesOut = i16ToPcmBytes(pcmOut);
    jbyteArray result = env->NewByteArray(static_cast<jsize>(pcmBytesOut.size()));
    if (result != nullptr && !pcmBytesOut.empty()) {
        env->SetByteArrayRegion(
                result, 0, static_cast<jsize>(pcmBytesOut.size()),
                reinterpret_cast<const jbyte *>(pcmBytesOut.data()));
    }
    return result;
}
