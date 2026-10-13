#ifndef MICBRIDGE_RT_H
#define MICBRIDGE_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "MBRing.h"
#include "MBInputStage.h"
#include "MBOutputStage.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Samples at or above this magnitude count as clipped. Just below 1.0 so that a 24-bit converter pinned at
/// its positive maximum (1 - 2^-23) is counted too.
#define MB_CLIP_THRESHOLD 0.9999f

/// Maximum number of output channels the mono signal is copied to (L + R).
#define MB_MAX_DESTINATIONS 2

/// Position of one channel inside an AudioBufferList: buffer index + channel index within that buffer.
/// The stride is read from the buffer itself at IO time.
typedef struct {
    uint32_t buffer;
    uint32_t channel;
} MBChannelRef;

// MARK: - Input IOProc (interface): selected channel → MBInputStage → ring

typedef struct MBInputIO MBInputIO;

MBInputIO *_Nullable mb_input_io_create(MBInputStage *_Nonnull stage);
/// Only after the IOProc has been destroyed.
void mb_input_io_destroy(MBInputIO *_Nullable io);
/// Lock-free; safe while IO runs.
void mb_input_io_set_source(MBInputIO *_Nonnull io, MBChannelRef source);
OSStatus mb_input_io_create_proc(AudioObjectID device, MBInputIO *_Nonnull io,
                                 AudioDeviceIOProcID _Nullable *_Nonnull out_proc);

// MARK: - Output IOProc (BlackHole): MBOutputStage → L + R

typedef struct MBOutputIO MBOutputIO;

MBOutputIO *_Nullable mb_output_io_create(MBOutputStage *_Nonnull stage);
void mb_output_io_destroy(MBOutputIO *_Nullable io);
/// Set before starting IO.
void mb_output_io_set_destinations(MBOutputIO *_Nonnull io, const MBChannelRef *_Nonnull destinations, uint32_t count);
OSStatus mb_output_io_create_proc(AudioObjectID device, MBOutputIO *_Nonnull io,
                                  AudioDeviceIOProcID _Nullable *_Nonnull out_proc);
uint64_t mb_output_io_cycles(const MBOutputIO *_Nonnull io);

// MARK: - Setup helpers

/// Enables/disables individual streams for an IOProc (kAudioDevicePropertyIOProcStreamUsage).
OSStatus mb_set_stream_usage(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, bool input,
                             const uint8_t *_Nonnull enabled, uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* MICBRIDGE_RT_H */
