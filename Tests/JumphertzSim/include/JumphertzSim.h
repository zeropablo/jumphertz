#ifndef JUMPHERTZ_SIM_H
#define JUMPHERTZ_SIM_H

#include <stdint.h>
#include "JumphertzRT.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Two independent simulated clocks driving the real input and output stages through the real ring:
/// the producer delivers `input_block` frames every block period of the input clock, the consumer asks for
/// `output_block` frames every block period of the output clock. Deterministic (fixed-seed jitter).
typedef struct {
    double input_rate;          // nominal
    double output_rate;
    double input_ppm;           // actual clock error of each device
    double output_ppm;
    uint32_t input_block;
    uint32_t output_block;
    double jitter;              // callback time jitter, fraction of a block period (0..0.4)
    int pass_rate_scalars;      // give the stages the true rate scalars (as the HAL would) or 0 (unknown)
    double seconds;
    double tone_hz;             // physical frequency of the input tone
    double amplitude;
    double settle_seconds;      // steady-state statistics are collected after this time
    // Disturbances (disabled when length is 0).
    double producer_pause_at, producer_pause_seconds;   // device unplugged: no input callbacks
    double consumer_pause_at, consumer_pause_seconds;   // output stalled
    double rate_change_at, rate_change_gap, new_input_rate;  // input side rebuilt at another rate
    // Optional capture of the output signal from capture_from (seconds) on.
    float *_Nullable capture;
    uint64_t capture_capacity;
    double capture_from;
    JHOutputTuning tuning;
} JHSimConfig;

typedef struct {
    uint64_t input_frames;          // produced by the input clock
    uint64_t output_frames;
    uint64_t underruns, overflows, dropped, resampler_errors;
    // Steady state (after settle_seconds, outside disturbances).
    uint32_t fill_min, fill_max;
    double fill_mean_first_half, fill_mean_second_half;
    double correction_min_ppm, correction_max_ppm;
    uint32_t target_fill;
    uint64_t silent_frames_after_settle;    // output frames written while not running
    // Whole run.
    double max_step;                // largest |x[n] - x[n-1]| of the output: click detector
    double max_step_at;             // ...and when it happened, seconds
    uint64_t non_finite;
    uint64_t captured;
    /// Longest stretch of output frames written while not running (gap duration), in frames.
    uint64_t longest_gap;
    /// Drift: slope of the loop's fill estimate (producer position − filter centre) over the steady window,
    /// least squares, in ppm of the input rate. 0 = consumption matches production exactly. (The raw fill also
    /// moves with the slowly sliding phase between the two clocks, which is not drift.)
    double fill_slope_ppm;
    /// Steady-state fill estimate used by the loop, min / max (input frames).
    double estimate_min, estimate_max;
    uint64_t timed_cycles;
    /// Latency measured by the output stage from the simulated timestamps (steady state), seconds.
    double latency_min, latency_mean, latency_max;
} JHSimResult;

JHSimConfig jh_sim_default_config(void);
int jh_sim_run(const JHSimConfig *_Nonnull config, JHSimResult *_Nonnull result);

/// THD+N of a sine of known frequency (least-squares fit of amplitude and phase), dB.
double jh_analysis_thdn(const float *_Nonnull x, uint64_t count, double rate, double frequency);
/// Level of one frequency relative to a full-scale (1.0) sine, dB (Hann-windowed Goertzel).
double jh_analysis_tone_level(const float *_Nonnull x, uint64_t count, double rate, double frequency);
/// Frequency of the dominant sine near `guess`, by phase slope between two halves. Hz.
double jh_analysis_frequency(const float *_Nonnull x, uint64_t count, double rate, double guess);

/// Quality over consecutive windows: each window's frequency is estimated first, so slow pitch corrections
/// (a few ppm) do not count as distortion. Returns the worst THD+N (dB) and fills the mean frequency (Hz) and
/// the largest deviation of a window's frequency from that mean (ppm).
double jh_analysis_windowed_thdn(const float *_Nonnull x, uint64_t count, double rate, double guess,
                                 uint64_t window, double *_Nonnull mean_frequency, double *_Nonnull max_deviation_ppm);

/// Two real threads hammering one ring with random chunk sizes; returns the number of out-of-order samples.
uint64_t jh_ring_stress(uint64_t total_samples, uint32_t capacity, uint32_t seed);

#ifdef __cplusplus
}
#endif

#endif
