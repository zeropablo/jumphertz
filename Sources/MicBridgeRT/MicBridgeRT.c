#include "MicBridgeRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// Packed channel reference: bit 63 = valid, bits 32..62 = buffer, bits 0..31 = channel.
#define MB_REF_VALID (1ULL << 63)

struct MBContext {
    _Atomic uint64_t source;
    _Atomic uint64_t destinations[MB_MAX_DESTINATIONS];
    _Atomic uint32_t destination_count;
    _Atomic uint32_t gain_bits;      // float bit pattern
    _Atomic uint32_t peak_bits;      // float bit pattern, always >= 0
    _Atomic uint64_t cycles;
    _Atomic uint64_t signal_cycles;
    _Atomic uint64_t clipped_samples;
    _Atomic uint32_t last_frames;
    float current_gain;              // touched by the IO thread only
};

static inline uint64_t pack_ref(MBChannelRef ref) {
    return MB_REF_VALID | ((uint64_t)(ref.buffer & 0x7FFFFFFFu) << 32) | (uint64_t)ref.channel;
}

static inline uint32_t float_bits(float f) {
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

static inline float bits_float(uint32_t u) {
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

// MARK: - Control thread

MBContext *mb_context_create(void) {
    MBContext *ctx = calloc(1, sizeof(MBContext));
    if (ctx == NULL) return NULL;
    atomic_init(&ctx->source, 0);
    for (int i = 0; i < MB_MAX_DESTINATIONS; i++) atomic_init(&ctx->destinations[i], 0);
    atomic_init(&ctx->destination_count, 0);
    atomic_init(&ctx->gain_bits, float_bits(1.0f));
    atomic_init(&ctx->peak_bits, 0);
    atomic_init(&ctx->cycles, 0);
    atomic_init(&ctx->signal_cycles, 0);
    atomic_init(&ctx->clipped_samples, 0);
    atomic_init(&ctx->last_frames, 0);
    ctx->current_gain = 1.0f;
    return ctx;
}

void mb_context_destroy(MBContext *ctx) {
    free(ctx);
}

void mb_context_set_source(MBContext *ctx, MBChannelRef source) {
    atomic_store_explicit(&ctx->source, pack_ref(source), memory_order_release);
}

void mb_context_set_destinations(MBContext *ctx, const MBChannelRef *destinations, uint32_t count) {
    if (count > MB_MAX_DESTINATIONS) count = MB_MAX_DESTINATIONS;
    atomic_store_explicit(&ctx->destination_count, 0, memory_order_release);
    for (uint32_t i = 0; i < count; i++) {
        atomic_store_explicit(&ctx->destinations[i], pack_ref(destinations[i]), memory_order_relaxed);
    }
    atomic_store_explicit(&ctx->destination_count, count, memory_order_release);
}

void mb_context_set_gain(MBContext *ctx, float linear_gain) {
    if (!isfinite(linear_gain) || linear_gain < 0.0f) linear_gain = 0.0f;
    // Before IO starts, also seed the ramp origin so the first buffer is not faded in.
    if (atomic_load_explicit(&ctx->cycles, memory_order_relaxed) == 0) ctx->current_gain = linear_gain;
    atomic_store_explicit(&ctx->gain_bits, float_bits(linear_gain), memory_order_release);
}

float mb_context_take_peak(MBContext *ctx) {
    return bits_float(atomic_exchange_explicit(&ctx->peak_bits, 0, memory_order_acq_rel));
}

uint64_t mb_context_cycle_count(MBContext *ctx) {
    return atomic_load_explicit(&ctx->cycles, memory_order_relaxed);
}

uint64_t mb_context_signal_cycle_count(MBContext *ctx) {
    return atomic_load_explicit(&ctx->signal_cycles, memory_order_relaxed);
}

uint64_t mb_context_clip_count(MBContext *ctx) {
    return atomic_load_explicit(&ctx->clipped_samples, memory_order_relaxed);
}

uint32_t mb_context_last_frames(MBContext *ctx) {
    return atomic_load_explicit(&ctx->last_frames, memory_order_relaxed);
}

// MARK: - IO thread
//
// Real-time rules: no allocation, no locks, no Objective-C/Swift, no logging, no syscalls.

static OSStatus mb_ioproc(AudioObjectID device,
                          const AudioTimeStamp *now,
                          const AudioBufferList *input,
                          const AudioTimeStamp *input_time,
                          AudioBufferList *output,
                          const AudioTimeStamp *output_time,
                          void *client_data) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    MBContext *ctx = (MBContext *)client_data;
    atomic_fetch_add_explicit(&ctx->cycles, 1, memory_order_relaxed);

    if (output == NULL) return noErr;

    // Resolve destinations.
    uint32_t dst_count = atomic_load_explicit(&ctx->destination_count, memory_order_acquire);
    float *dst[MB_MAX_DESTINATIONS];
    uint32_t dst_stride[MB_MAX_DESTINATIONS];
    uint32_t frames = UINT32_MAX;
    uint32_t valid_dst = 0;
    for (uint32_t i = 0; i < dst_count && i < MB_MAX_DESTINATIONS; i++) {
        uint64_t packed = atomic_load_explicit(&ctx->destinations[i], memory_order_relaxed);
        if (!(packed & MB_REF_VALID)) continue;
        uint32_t b = (uint32_t)((packed >> 32) & 0x7FFFFFFFu);
        uint32_t c = (uint32_t)(packed & 0xFFFFFFFFu);
        if (b >= output->mNumberBuffers) continue;
        AudioBuffer *buf = &output->mBuffers[b];
        if (buf->mData == NULL || buf->mNumberChannels == 0 || c >= buf->mNumberChannels) continue;
        uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        if (n < frames) frames = n;
        dst[valid_dst] = (float *)buf->mData + c;
        dst_stride[valid_dst] = buf->mNumberChannels;
        valid_dst++;
    }
    if (valid_dst == 0 || frames == UINT32_MAX || frames == 0) return noErr;
    atomic_store_explicit(&ctx->last_frames, frames, memory_order_relaxed);

    // Resolve source.
    const float *src = NULL;
    uint32_t src_stride = 0;
    uint64_t packed = atomic_load_explicit(&ctx->source, memory_order_acquire);
    if (input != NULL && (packed & MB_REF_VALID)) {
        uint32_t b = (uint32_t)((packed >> 32) & 0x7FFFFFFFu);
        uint32_t c = (uint32_t)(packed & 0xFFFFFFFFu);
        if (b < input->mNumberBuffers) {
            const AudioBuffer *buf = &input->mBuffers[b];
            if (buf->mData != NULL && buf->mNumberChannels > 0 && c < buf->mNumberChannels) {
                uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
                if (n < frames) frames = n;
                src = (const float *)buf->mData + c;
                src_stride = buf->mNumberChannels;
            }
        }
    }

    if (src == NULL) {
        for (uint32_t d = 0; d < valid_dst; d++) {
            for (uint32_t f = 0; f < frames; f++) dst[d][f * dst_stride[d]] = 0.0f;
        }
        return noErr;
    }

    // Copy with a linear gain ramp over the buffer (click-free gain changes) and hard clip.
    float target = bits_float(atomic_load_explicit(&ctx->gain_bits, memory_order_acquire));
    float gain = ctx->current_gain;
    float step = (target - gain) / (float)frames;
    float peak = 0.0f;
    uint32_t nonzero = 0;
    uint32_t clipped = 0;

    for (uint32_t f = 0; f < frames; f++) {
        float in = src[f * src_stride];
        nonzero |= (in != 0.0f);
        gain += step;
        float s = in * gain;
        float a = fabsf(s);
        if (a >= MB_CLIP_THRESHOLD) {
            clipped++;
            if (a > 1.0f) {
                s = s > 0.0f ? 1.0f : -1.0f;
                a = 1.0f;
            }
        }
        if (a > peak) peak = a;
        for (uint32_t d = 0; d < valid_dst; d++) dst[d][f * dst_stride[d]] = s;
    }
    ctx->current_gain = target;

    if (nonzero) atomic_fetch_add_explicit(&ctx->signal_cycles, 1, memory_order_relaxed);
    if (clipped) atomic_fetch_add_explicit(&ctx->clipped_samples, clipped, memory_order_relaxed);
    // Non-negative floats order like their bit patterns; a lost update only drops one buffer of VU data.
    uint32_t peak_bits = float_bits(peak);
    if (peak_bits > atomic_load_explicit(&ctx->peak_bits, memory_order_relaxed)) {
        atomic_store_explicit(&ctx->peak_bits, peak_bits, memory_order_relaxed);
    }
    return noErr;
}

// MARK: - Setup helpers (control thread)

OSStatus mb_create_ioproc(AudioObjectID device, MBContext *ctx, AudioDeviceIOProcID *out_proc) {
    return AudioDeviceCreateIOProcID(device, mb_ioproc, ctx, out_proc);
}

OSStatus mb_set_stream_usage(AudioObjectID device, AudioDeviceIOProcID proc, bool input,
                             const uint8_t *enabled, uint32_t count) {
    UInt32 size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32) * count);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (usage == NULL) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    for (uint32_t i = 0; i < count; i++) usage->mStreamIsOn[i] = enabled[i] ? 1 : 0;

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage,
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    free(usage);
    return status;
}
