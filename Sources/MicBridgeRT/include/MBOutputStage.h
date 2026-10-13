#ifndef MICBRIDGE_OUTPUT_STAGE_H
#define MICBRIDGE_OUTPUT_STAGE_H

#include <stdint.h>
#include "MBRing.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Consumer side: ring (input rate, input clock) → variable-ratio resampler → output (fixed rate, output clock).
/// The ratio follows the HAL rate scalars of both clocks and a PI loop on the ring fill level, so the two
/// clocks can drift without the ring ever running dry or overflowing. Runs in the output device's IOProc.
typedef struct MBOutputStage MBOutputStage;

typedef enum {
    /// No input stream announced: writes silence.
    MBOutputStateSilent = 0,
    /// Waiting for the ring to reach its target fill (start, after an underrun/overflow or a format change).
    MBOutputStateRefill = 1,
    MBOutputStateRunning = 2,
} MBOutputState;

typedef struct {
    /// Proportional gain, 1/s: correction (fraction of rate) per second of fill error.
    double kp;
    /// Integral gain, 1/s².
    double ki;
    /// Maximum correction, as a fraction of the rate (5e-4 = 500 ppm ≈ 0.9 cent).
    double max_correction;
    /// Time constant of the fill level low-pass filter, seconds.
    double fill_filter_seconds;
    /// Safety margin added to the target fill, seconds of input.
    double margin_seconds;
    /// Fade-in after (re)start and fade-out to silence, seconds.
    double fade_in_seconds;
    double fade_out_seconds;
} MBOutputTuning;

typedef struct {
    MBOutputState state;
    double input_rate;
    double output_rate;
    /// Ring fill at the last cycle, fill estimate used by the loop (timestamp-extrapolated when available),
    /// filtered estimate and target, in input frames.
    uint32_t fill;
    double estimated_fill;
    double filtered_fill;
    uint32_t target_fill;
    /// Current PI correction in ppm (positive = consuming input faster).
    double correction_ppm;
    /// Last resampler ratio (output frames per input frame).
    double ratio;
    uint64_t cycles;
    uint64_t underruns;
    uint64_t overflows;
    uint64_t resampler_errors;
    /// Cycles where the loop used the timestamp-based estimate (vs. the raw fill).
    uint64_t timed_cycles;
    /// 0 = medium quality sinc, 1 = fastest sinc (used above 50 kHz input).
    int converter;
} MBOutputStats;

MBOutputTuning mb_output_default_tuning(void);

// MARK: Control thread (allocates)

/// `max_frames`: largest block processed at once (bigger IO blocks are split). Creates both resamplers.
MBOutputStage *_Nullable mb_output_create(MBRing *_Nonnull ring, double output_rate, uint32_t max_frames,
                                          MBOutputTuning tuning);
/// Only after the IOProc using it has been destroyed.
void mb_output_destroy(MBOutputStage *_Nullable stage);

/// Announces the rate of everything the producer writes from now on (0 = no producer). Lock-free. The output
/// fades to silence, discards what is in the ring, refills and fades back in. Its own rate never changes.
void mb_output_set_input_rate(MBOutputStage *_Nonnull stage, double input_rate);

// MARK: Real time

/// Writes `frames` frames to each of the `count` destinations (interleaved buffers, one channel each).
/// `output_rate_scalar`: the HAL's mRateScalar of the cycle (0 if unknown).
/// `host_seconds`: ideal time of the IO cycle (mHostTime in seconds, 0 if unknown). With the producer's
/// timing it gives a fill estimate independent of the callbacks' order; without, the raw fill is used.
void mb_output_process(MBOutputStage *_Nonnull stage, float *_Nonnull const *_Nonnull destinations,
                       const uint32_t *_Nonnull strides, uint32_t count, uint32_t frames,
                       double output_rate_scalar, double host_seconds);

// MARK: Statistics (any thread, each field individually consistent)

void mb_output_get_stats(const MBOutputStage *_Nonnull stage, MBOutputStats *_Nonnull stats);

#ifdef __cplusplus
}
#endif

#endif
