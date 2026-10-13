#ifndef MICBRIDGE_RT_H
#define MICBRIDGE_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Maximum number of output channels the source is copied to (mono -> L + R).
#define MB_MAX_DESTINATIONS 2

/// Samples at or above this magnitude count as clipped. Just below 1.0 so that a 24-bit converter pinned at
/// its positive maximum (1 - 2^-23) is counted too.
#define MB_CLIP_THRESHOLD 0.9999f

/// Opaque real-time context. Allocated once on the control thread, handed to the IOProc as client data.
typedef struct MBContext MBContext;

/// Position of one channel inside an AudioBufferList: buffer index + channel index within that buffer.
/// The stride is read from the buffer itself at IO time.
typedef struct {
    uint32_t buffer;
    uint32_t channel;
} MBChannelRef;

// MARK: - Control thread API (may allocate, never called from the IOProc)

MBContext *_Nullable mb_context_create(void);
/// Only call after the IOProc has been destroyed.
void mb_context_destroy(MBContext *_Nullable ctx);

/// Lock-free; safe to call while IO is running.
void mb_context_set_source(MBContext *_Nonnull ctx, MBChannelRef source);
/// Set before starting IO.
void mb_context_set_destinations(MBContext *_Nonnull ctx, const MBChannelRef *_Nonnull destinations, uint32_t count);
/// Lock-free; safe to call while IO is running. The IOProc ramps to the new value over one buffer.
void mb_context_set_gain(MBContext *_Nonnull ctx, float linear_gain);

/// Peak absolute output sample since the previous call (resets it to 0).
float mb_context_take_peak(MBContext *_Nonnull ctx);
/// Number of IO cycles executed.
uint64_t mb_context_cycle_count(MBContext *_Nonnull ctx);
/// Number of IO cycles in which the source contained at least one non-zero sample.
uint64_t mb_context_signal_cycle_count(MBContext *_Nonnull ctx);
/// Number of output samples at or beyond full scale (|x| >= MB_CLIP_THRESHOLD, before the hard clip).
uint64_t mb_context_clip_count(MBContext *_Nonnull ctx);
/// Frames processed in the most recent IO cycle.
uint32_t mb_context_last_frames(MBContext *_Nonnull ctx);

/// Creates the IOProc on `device` with `ctx` as client data.
OSStatus mb_create_ioproc(AudioObjectID device, MBContext *_Nonnull ctx, AudioDeviceIOProcID _Nullable *_Nonnull out_proc);

/// Enables/disables individual streams for an IOProc (kAudioDevicePropertyIOProcStreamUsage).
OSStatus mb_set_stream_usage(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, bool input,
                             const uint8_t *_Nonnull enabled, uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* MICBRIDGE_RT_H */
