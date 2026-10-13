#ifndef JUMPHERTZ_INPUT_STAGE_H
#define JUMPHERTZ_INPUT_STAGE_H

#include <stdint.h>
#include "JHRing.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Producer side: one input channel → gain (ramped) → ring. Runs in the interface's IOProc.
typedef struct JHInputStage JHInputStage;

// MARK: Control thread

/// `input_rate`: nominal rate of the interface for the lifetime of this stage.
JHInputStage *_Nullable jh_input_create(JHRing *_Nonnull ring, double input_rate);
/// Only after the IOProc using it has been destroyed.
void jh_input_destroy(JHInputStage *_Nullable stage);
/// Lock-free, applied with a ramp over the next block.
void jh_input_set_gain(JHInputStage *_Nonnull stage, float linear_gain);

// MARK: Real time

/// `samples` points at the selected channel inside an interleaved buffer of `stride` channels.
/// `rate_scalar`: the HAL's mRateScalar of the cycle (0 if unknown).
/// `host_seconds`: ideal time of the IO cycle (inNow, in seconds; 0 if unknown).
/// `capture_seconds`: when the first frame of this block was captured (inInputTime; 0 if unknown).
void jh_input_process(JHInputStage *_Nonnull stage, const float *_Nonnull samples, uint32_t stride,
                      uint32_t frames, double rate_scalar, double host_seconds, double capture_seconds);

// MARK: Statistics (any thread)

float jh_input_take_peak(JHInputStage *_Nonnull stage);
uint64_t jh_input_cycles(const JHInputStage *_Nonnull stage);
uint64_t jh_input_signal_cycles(const JHInputStage *_Nonnull stage);
uint64_t jh_input_clipped_samples(const JHInputStage *_Nonnull stage);
/// Samples that did not fit in the ring (consumer stalled).
uint64_t jh_input_dropped_samples(const JHInputStage *_Nonnull stage);
uint32_t jh_input_last_frames(const JHInputStage *_Nonnull stage);

#ifdef __cplusplus
}
#endif

#endif
