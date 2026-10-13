#ifndef MICBRIDGE_INPUT_STAGE_H
#define MICBRIDGE_INPUT_STAGE_H

#include <stdint.h>
#include "MBRing.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Producer side: one input channel → gain (ramped) → ring. Runs in the interface's IOProc.
typedef struct MBInputStage MBInputStage;

// MARK: Control thread

/// `input_rate`: nominal rate of the interface for the lifetime of this stage.
MBInputStage *_Nullable mb_input_create(MBRing *_Nonnull ring, double input_rate);
/// Only after the IOProc using it has been destroyed.
void mb_input_destroy(MBInputStage *_Nullable stage);
/// Lock-free, applied with a ramp over the next block.
void mb_input_set_gain(MBInputStage *_Nonnull stage, float linear_gain);

// MARK: Real time

/// `samples` points at the selected channel inside an interleaved buffer of `stride` channels.
/// `rate_scalar`: the HAL's mRateScalar of the cycle (0 if unknown).
/// `host_seconds`: ideal time of the IO cycle (mHostTime in seconds, 0 if unknown).
void mb_input_process(MBInputStage *_Nonnull stage, const float *_Nonnull samples, uint32_t stride,
                      uint32_t frames, double rate_scalar, double host_seconds);

// MARK: Statistics (any thread)

float mb_input_take_peak(MBInputStage *_Nonnull stage);
uint64_t mb_input_cycles(const MBInputStage *_Nonnull stage);
uint64_t mb_input_signal_cycles(const MBInputStage *_Nonnull stage);
uint64_t mb_input_clipped_samples(const MBInputStage *_Nonnull stage);
/// Samples that did not fit in the ring (consumer stalled).
uint64_t mb_input_dropped_samples(const MBInputStage *_Nonnull stage);
uint32_t mb_input_last_frames(const MBInputStage *_Nonnull stage);

#ifdef __cplusplus
}
#endif

#endif
