#ifndef JUMPHERTZ_RT_H
#define JUMPHERTZ_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "JHRing.h"
#include "JHInputStage.h"
#include "JHOutputStage.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Samples at or above this magnitude count as clipped. Just below 1.0 so that a 24-bit converter pinned at
/// its positive maximum (1 - 2^-23) is counted too.
#define JH_CLIP_THRESHOLD 0.9999f

/// Maximum number of output channels the mono signal is copied to (L + R).
#define JH_MAX_DESTINATIONS 2

/// Position of one channel inside an AudioBufferList: buffer index + channel index within that buffer.
/// The stride is read from the buffer itself at IO time.
typedef struct {
    uint32_t buffer;
    uint32_t channel;
} JHChannelRef;

// MARK: - Input IOProc (interface): selected channel → JHInputStage → ring

typedef struct JHInputIO JHInputIO;

JHInputIO *_Nullable jh_input_io_create(JHInputStage *_Nonnull stage);
/// Only after the IOProc has been destroyed.
void jh_input_io_destroy(JHInputIO *_Nullable io);
/// Lock-free; safe while IO runs.
void jh_input_io_set_source(JHInputIO *_Nonnull io, JHChannelRef source);
OSStatus jh_input_io_create_proc(AudioObjectID device, JHInputIO *_Nonnull io,
                                 AudioDeviceIOProcID _Nullable *_Nonnull out_proc);

// MARK: - Output IOProc (BlackHole): JHOutputStage → L + R

typedef struct JHOutputIO JHOutputIO;

JHOutputIO *_Nullable jh_output_io_create(JHOutputStage *_Nonnull stage);
void jh_output_io_destroy(JHOutputIO *_Nullable io);
/// Set before starting IO.
void jh_output_io_set_destinations(JHOutputIO *_Nonnull io, const JHChannelRef *_Nonnull destinations, uint32_t count);
OSStatus jh_output_io_create_proc(AudioObjectID device, JHOutputIO *_Nonnull io,
                                  AudioDeviceIOProcID _Nullable *_Nonnull out_proc);
uint64_t jh_output_io_cycles(const JHOutputIO *_Nonnull io);

// MARK: - Setup helpers

/// Enables/disables individual streams for an IOProc (kAudioDevicePropertyIOProcStreamUsage).
OSStatus jh_set_stream_usage(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, bool input,
                             const uint8_t *_Nonnull enabled, uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* JUMPHERTZ_RT_H */
