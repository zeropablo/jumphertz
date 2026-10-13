#ifndef JUMPHERTZ_OUTPUT_STAGE_H
#define JUMPHERTZ_OUTPUT_STAGE_H

#include <stdint.h>
#include "JHRing.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Consumer side: ring (input rate, input clock) → variable-ratio resampler → output (fixed rate, output clock).
/// The ratio follows the HAL rate scalars of both clocks and a PI loop on the ring fill level, so the two
/// clocks can drift without the ring ever running dry or overflowing. Runs in the output device's IOProc.
typedef struct JHOutputStage JHOutputStage;

typedef enum {
    /// No input stream announced: writes silence.
    JHOutputStateSilent = 0,
    /// Waiting for the ring to reach its target fill (start, after an underrun/overflow or a format change).
    JHOutputStateRefill = 1,
    JHOutputStateRunning = 2,
} JHOutputState;

typedef struct {
    /// Proportional gain, 1/s: correction (fraction of rate) per second of fill error.
    double kp;
    /// Integral gain, 1/s².
    double ki;
    /// Maximum correction, as a fraction of the rate (5e-4 = 500 ppm ≈ 0.9 cent).
    double max_correction;
    /// Time constant of the fill level low-pass filter, seconds.
    double fill_filter_seconds;
    /// Safety margin added to the target fill, seconds of input...
    double margin_seconds;
    /// ...plus this fraction of a producer block, for late input callbacks (scheduling jitter).
    double producer_margin_fraction;
    /// Fade-in after (re)start and fade-out to silence, seconds.
    double fade_in_seconds;
    double fade_out_seconds;
} JHOutputTuning;

typedef struct {
    JHOutputState state;
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
    /// Measured latency, seconds: from the capture of a sample at the input device to its presentation in the
    /// output device, from the HAL timestamps of both IO cycles. Last value, and min / mean / max since the
    /// last jh_output_reset_latency(). count = 0 when nothing was measured.
    double latency_last;
    double latency_min;
    double latency_mean;
    double latency_max;
    uint64_t latency_count;
} JHOutputStats;

/// Safe defaults (the margins validated in simulation with ±20 % callback jitter).
JHOutputTuning jh_output_default_tuning(void);
/// Reduced jitter margin: lower latency, to be validated on the actual hardware.
JHOutputTuning jh_output_reduced_margin_tuning(void);

// MARK: Control thread (allocates)

/// `max_frames`: largest block processed at once (bigger IO blocks are split). Creates both resamplers.
JHOutputStage *_Nullable jh_output_create(JHRing *_Nonnull ring, double output_rate, uint32_t max_frames,
                                          JHOutputTuning tuning);
/// Only after the IOProc using it has been destroyed.
void jh_output_destroy(JHOutputStage *_Nullable stage);

/// Announces the rate of everything the producer writes from now on (0 = no producer). Lock-free. The output
/// fades to silence, discards what is in the ring, refills and fades back in. Its own rate never changes.
void jh_output_set_input_rate(JHOutputStage *_Nonnull stage, double input_rate);

// MARK: Real time

/// Writes `frames` frames to each of the `count` destinations (interleaved buffers, one channel each).
/// `output_rate_scalar`: the HAL's mRateScalar of the cycle (0 if unknown).
/// `host_seconds`: ideal time of the IO cycle (inNow in seconds, 0 if unknown). With the producer's
/// timing it gives a fill estimate independent of the callbacks' order; without, the raw fill is used.
/// `present_seconds`: when the first frame written here will be presented (inOutputTime, 0 if unknown);
/// used for the latency measurement only.
void jh_output_process(JHOutputStage *_Nonnull stage, float *_Nonnull const *_Nonnull destinations,
                       const uint32_t *_Nonnull strides, uint32_t count, uint32_t frames,
                       double output_rate_scalar, double host_seconds, double present_seconds);

// MARK: Statistics (any thread, each field individually consistent)

void jh_output_get_stats(const JHOutputStage *_Nonnull stage, JHOutputStats *_Nonnull stats);
/// Starts a new min / mean / max latency window (applied by the IO thread at its next cycle).
void jh_output_reset_latency(JHOutputStage *_Nonnull stage);

#ifdef __cplusplus
}
#endif

#endif
