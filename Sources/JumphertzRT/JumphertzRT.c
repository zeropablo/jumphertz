#include "JumphertzRT.h"

#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// Packed channel reference: bit 63 = valid, bits 32..62 = buffer, bits 0..31 = channel.
#define JH_REF_VALID (1ULL << 63)

static inline uint64_t pack_ref(JHChannelRef ref) {
    return JH_REF_VALID | ((uint64_t)(ref.buffer & 0x7FFFFFFFu) << 32) | (uint64_t)ref.channel;
}

static inline bool unpack_ref(uint64_t packed, uint32_t *buffer, uint32_t *channel) {
    if (!(packed & JH_REF_VALID)) return false;
    *buffer = (uint32_t)((packed >> 32) & 0x7FFFFFFFu);
    *channel = (uint32_t)(packed & 0xFFFFFFFFu);
    return true;
}

/// Host ticks → seconds, computed once on the control thread.
static double host_ticks_to_seconds(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return (double)info.numer / (double)info.denom * 1e-9;
}

static inline double host_seconds(const AudioTimeStamp *t, double factor) {
    return (t != NULL && (t->mFlags & kAudioTimeStampHostTimeValid)) ? (double)t->mHostTime * factor : 0.0;
}

static inline double rate_scalar(const AudioTimeStamp *t) {
    return (t != NULL && (t->mFlags & kAudioTimeStampRateScalarValid)) ? t->mRateScalar : 0.0;
}

// Real-time rules for both IOProcs: no allocation, no locks, no Objective-C/Swift, no logging, no syscalls.

// MARK: - Input

struct JHInputIO {
    JHInputStage *stage;
    _Atomic uint64_t source;
    double ticks_to_seconds;
};

JHInputIO *jh_input_io_create(JHInputStage *stage) {
    JHInputIO *io = calloc(1, sizeof(JHInputIO));
    if (io == NULL) return NULL;
    io->stage = stage;
    atomic_init(&io->source, 0);
    io->ticks_to_seconds = host_ticks_to_seconds();
    return io;
}

void jh_input_io_destroy(JHInputIO *io) { free(io); }

void jh_input_io_set_source(JHInputIO *io, JHChannelRef source) {
    atomic_store_explicit(&io->source, pack_ref(source), memory_order_release);
}

static OSStatus jh_input_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                                const AudioTimeStamp *input_time, AudioBufferList *output,
                                const AudioTimeStamp *output_time, void *client_data) {
    (void)device; (void)output; (void)output_time;
    JHInputIO *io = (JHInputIO *)client_data;
    uint32_t b, c;
    if (input == NULL || !unpack_ref(atomic_load_explicit(&io->source, memory_order_acquire), &b, &c)) return noErr;
    if (b >= input->mNumberBuffers) return noErr;
    const AudioBuffer *buf = &input->mBuffers[b];
    if (buf->mData == NULL || buf->mNumberChannels == 0 || c >= buf->mNumberChannels) return noErr;
    uint32_t frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
    jh_input_process(io->stage, (const float *)buf->mData + c, buf->mNumberChannels, frames,
                     rate_scalar(input_time), host_seconds(now, io->ticks_to_seconds),
                     host_seconds(input_time, io->ticks_to_seconds));
    return noErr;
}

OSStatus jh_input_io_create_proc(AudioObjectID device, JHInputIO *io, AudioDeviceIOProcID *out_proc) {
    return AudioDeviceCreateIOProcID(device, jh_input_ioproc, io, out_proc);
}

// MARK: - Output

struct JHOutputIO {
    JHOutputStage *stage;
    _Atomic uint64_t destinations[JH_MAX_DESTINATIONS];
    _Atomic uint32_t destination_count;
    _Atomic uint64_t cycles;
    double ticks_to_seconds;
};

JHOutputIO *jh_output_io_create(JHOutputStage *stage) {
    JHOutputIO *io = calloc(1, sizeof(JHOutputIO));
    if (io == NULL) return NULL;
    io->stage = stage;
    for (int i = 0; i < JH_MAX_DESTINATIONS; i++) atomic_init(&io->destinations[i], 0);
    atomic_init(&io->destination_count, 0);
    atomic_init(&io->cycles, 0);
    io->ticks_to_seconds = host_ticks_to_seconds();
    return io;
}

void jh_output_io_destroy(JHOutputIO *io) { free(io); }

void jh_output_io_set_destinations(JHOutputIO *io, const JHChannelRef *destinations, uint32_t count) {
    if (count > JH_MAX_DESTINATIONS) count = JH_MAX_DESTINATIONS;
    atomic_store_explicit(&io->destination_count, 0, memory_order_release);
    for (uint32_t i = 0; i < count; i++) {
        atomic_store_explicit(&io->destinations[i], pack_ref(destinations[i]), memory_order_relaxed);
    }
    atomic_store_explicit(&io->destination_count, count, memory_order_release);
}

uint64_t jh_output_io_cycles(const JHOutputIO *io) {
    return atomic_load_explicit(&((JHOutputIO *)io)->cycles, memory_order_relaxed);
}

static OSStatus jh_output_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                                 const AudioTimeStamp *input_time, AudioBufferList *output,
                                 const AudioTimeStamp *output_time, void *client_data) {
    (void)device; (void)input; (void)input_time;
    JHOutputIO *io = (JHOutputIO *)client_data;
    atomic_fetch_add_explicit(&io->cycles, 1, memory_order_relaxed);
    if (output == NULL) return noErr;

    float *dst[JH_MAX_DESTINATIONS];
    uint32_t stride[JH_MAX_DESTINATIONS];
    uint32_t count = 0, frames = UINT32_MAX;
    uint32_t wanted = atomic_load_explicit(&io->destination_count, memory_order_acquire);
    for (uint32_t i = 0; i < wanted && i < JH_MAX_DESTINATIONS; i++) {
        uint32_t b, c;
        if (!unpack_ref(atomic_load_explicit(&io->destinations[i], memory_order_relaxed), &b, &c)) continue;
        if (b >= output->mNumberBuffers) continue;
        AudioBuffer *buf = &output->mBuffers[b];
        if (buf->mData == NULL || buf->mNumberChannels == 0 || c >= buf->mNumberChannels) continue;
        uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        if (n < frames) frames = n;
        dst[count] = (float *)buf->mData + c;
        stride[count] = buf->mNumberChannels;
        count++;
    }
    if (count == 0 || frames == UINT32_MAX || frames == 0) return noErr;
    jh_output_process(io->stage, dst, stride, count, frames, rate_scalar(output_time),
                      host_seconds(now, io->ticks_to_seconds), host_seconds(output_time, io->ticks_to_seconds));
    return noErr;
}

OSStatus jh_output_io_create_proc(AudioObjectID device, JHOutputIO *io, AudioDeviceIOProcID *out_proc) {
    return AudioDeviceCreateIOProcID(device, jh_output_ioproc, io, out_proc);
}

// MARK: - Setup helpers (control thread)

OSStatus jh_set_stream_usage(AudioObjectID device, AudioDeviceIOProcID proc, bool input,
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
