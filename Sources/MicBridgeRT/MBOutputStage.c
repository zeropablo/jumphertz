#include "MBOutputStage.h"

#include <math.h>
#include <samplerate.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// Above this input rate the cheaper sinc is used (downsampling with the medium filter costs twice as much).
#define MB_FAST_CONVERTER_ABOVE 50000.0
/// HAL rate scalars outside this range are treated as unknown.
#define MB_SCALAR_MIN 0.99
#define MB_SCALAR_MAX 1.01

struct MBOutputStage {
    MBRing *ring;
    double output_rate;
    uint32_t max_frames;
    float *scratch;
    SRC_STATE *converters[2];   // [0] medium, [1] fastest
    MBOutputTuning tuning;

    // Control → IO thread.
    _Atomic uint64_t requested_epoch;
    _Atomic uint64_t requested_rate_bits;

    // IO thread only.
    uint64_t epoch;
    double input_rate;
    int converter;
    MBOutputState state;
    double filtered_fill;
    double integral;
    double correction;
    double position;          // input frame index of the resampler's filter centre (ring index units)
    double src_last_ratio;    // mirror of the resampler's internal last ratio
    float last_sample;
    float decay_from;
    uint32_t decay_pos;
    uint32_t fade_pos;

    // Statistics (IO thread writes, anyone reads).
    _Atomic uint32_t stat_state;
    _Atomic uint64_t stat_input_rate_bits;
    _Atomic uint32_t stat_fill;
    _Atomic uint64_t stat_estimated_bits;
    _Atomic uint64_t stat_timed;
    _Atomic uint64_t stat_filtered_fill_bits;
    _Atomic uint32_t stat_target;
    _Atomic uint64_t stat_correction_bits;
    _Atomic uint64_t stat_ratio_bits;
    _Atomic uint64_t stat_cycles;
    _Atomic uint64_t stat_underruns;
    _Atomic uint64_t stat_overflows;
    _Atomic uint64_t stat_errors;
    _Atomic uint32_t stat_converter;
};

static inline uint64_t d2b(double d) { uint64_t u; memcpy(&u, &d, sizeof u); return u; }
static inline double b2d(uint64_t u) { double d; memcpy(&d, &u, sizeof d); return d; }
static inline double clampd(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

MBOutputTuning mb_output_default_tuning(void) {
    MBOutputTuning t = {
        .kp = 0.1,                 // 1 ms of fill error → 100 ppm; loop time constant ≈ 10 s
        .ki = 0.0025,              // kp² / 4: critically damped
        .max_correction = 5e-4,    // ±500 ppm
        .fill_filter_seconds = 0.5,
        .margin_seconds = 0.0025,
        .fade_in_seconds = 0.005,
        .fade_out_seconds = 0.002,
    };
    return t;
}

// MARK: - Control thread

MBOutputStage *mb_output_create(MBRing *ring, double output_rate, uint32_t max_frames, MBOutputTuning tuning) {
    if (output_rate <= 0 || max_frames == 0) return NULL;
    MBOutputStage *s = calloc(1, sizeof(MBOutputStage));
    if (s == NULL) return NULL;
    s->ring = ring;
    s->output_rate = output_rate;
    s->max_frames = max_frames;
    s->tuning = tuning;
    s->scratch = calloc(max_frames, sizeof(float));
    int error = 0;
    s->converters[0] = src_new(SRC_SINC_MEDIUM_QUALITY, 1, &error);
    s->converters[1] = src_new(SRC_SINC_FASTEST, 1, &error);
    if (s->scratch == NULL || s->converters[0] == NULL || s->converters[1] == NULL) {
        mb_output_destroy(s);
        return NULL;
    }
    atomic_init(&s->requested_epoch, 0);
    atomic_init(&s->requested_rate_bits, d2b(0));
    s->state = MBOutputStateSilent;
    atomic_init(&s->stat_state, MBOutputStateSilent);
    atomic_init(&s->stat_input_rate_bits, d2b(0));
    atomic_init(&s->stat_fill, 0);
    atomic_init(&s->stat_estimated_bits, d2b(0));
    atomic_init(&s->stat_timed, 0);
    atomic_init(&s->stat_filtered_fill_bits, d2b(0));
    atomic_init(&s->stat_target, 0);
    atomic_init(&s->stat_correction_bits, d2b(0));
    atomic_init(&s->stat_ratio_bits, d2b(0));
    atomic_init(&s->stat_cycles, 0);
    atomic_init(&s->stat_underruns, 0);
    atomic_init(&s->stat_overflows, 0);
    atomic_init(&s->stat_errors, 0);
    atomic_init(&s->stat_converter, 0);
    return s;
}

void mb_output_destroy(MBOutputStage *s) {
    if (s == NULL) return;
    if (s->converters[0]) src_delete(s->converters[0]);
    if (s->converters[1]) src_delete(s->converters[1]);
    free(s->scratch);
    free(s);
}

void mb_output_set_input_rate(MBOutputStage *s, double input_rate) {
    atomic_store_explicit(&s->requested_rate_bits, d2b(input_rate > 0 ? input_rate : 0), memory_order_relaxed);
    atomic_fetch_add_explicit(&s->requested_epoch, 1, memory_order_release);
}

void mb_output_get_stats(const MBOutputStage *cs, MBOutputStats *out) {
    MBOutputStage *s = (MBOutputStage *)cs;
    out->state = (MBOutputState)atomic_load_explicit(&s->stat_state, memory_order_relaxed);
    out->input_rate = b2d(atomic_load_explicit(&s->stat_input_rate_bits, memory_order_relaxed));
    out->output_rate = s->output_rate;
    out->fill = atomic_load_explicit(&s->stat_fill, memory_order_relaxed);
    out->estimated_fill = b2d(atomic_load_explicit(&s->stat_estimated_bits, memory_order_relaxed));
    out->timed_cycles = atomic_load_explicit(&s->stat_timed, memory_order_relaxed);
    out->filtered_fill = b2d(atomic_load_explicit(&s->stat_filtered_fill_bits, memory_order_relaxed));
    out->target_fill = atomic_load_explicit(&s->stat_target, memory_order_relaxed);
    out->correction_ppm = b2d(atomic_load_explicit(&s->stat_correction_bits, memory_order_relaxed)) * 1e6;
    out->ratio = b2d(atomic_load_explicit(&s->stat_ratio_bits, memory_order_relaxed));
    out->cycles = atomic_load_explicit(&s->stat_cycles, memory_order_relaxed);
    out->underruns = atomic_load_explicit(&s->stat_underruns, memory_order_relaxed);
    out->overflows = atomic_load_explicit(&s->stat_overflows, memory_order_relaxed);
    out->resampler_errors = atomic_load_explicit(&s->stat_errors, memory_order_relaxed);
    out->converter = (int)atomic_load_explicit(&s->stat_converter, memory_order_relaxed);
}

// MARK: - IO thread
//
// Real-time rules: no allocation, no locks, no Objective-C/Swift, no logging, no syscalls.
// src_process / src_reset only touch memory allocated by src_new.

static inline void count(_Atomic uint64_t *counter) {
    atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
}

/// Half length of the resampler's filter, in input frames, at ratio ≥ 1 (from the coefficient tables:
/// (coefficients + 2) / increment, rounded up, +1). Downsampling stretches it by 1 / ratio.
#define MB_HALF_FILTER_MEDIUM 47.0
#define MB_HALF_FILTER_FASTEST 21.0

static double half_filter(const MBOutputStage *s) {
    double base = s->converter == 1 ? MB_HALF_FILTER_FASTEST : MB_HALF_FILTER_MEDIUM;
    double ratio = s->output_rate / s->input_rate;
    return ceil(base * (ratio < 1.0 ? 1.0 / ratio : 1.0)) + 2.0;
}

/// Target for the fill estimate (input frames between the producer's extrapolated write position and the
/// resampler's filter centre). The producer's data arrives in bursts, up to one producer block behind the
/// extrapolated position; the next output block consumes one consumer block plus half a filter of look-ahead;
/// the margin absorbs callback scheduling jitter.
static uint32_t target_fill(const MBOutputStage *s, uint32_t frames) {
    double consumer = ceil(frames * s->input_rate / s->output_rate);
    double producer = mb_ring_producer_block(s->ring);
    if (producer == 0) producer = consumer;
    double margin = fmax(64.0, s->tuning.margin_seconds * s->input_rate) + producer / 4.0;
    double target = producer + consumer + half_filter(s) + margin;
    double limit = mb_ring_capacity(s->ring) / 2.0;
    return (uint32_t)(target < limit ? target : limit);
}

/// Fill above which the consumer is considered to have stalled: drop to the target.
static uint32_t high_water(const MBOutputStage *s, uint32_t target) {
    uint32_t high = target * 4 + 2048;
    uint32_t limit = mb_ring_capacity(s->ring) * 3 / 4;
    return high < limit ? high : limit;
}

static void begin_silence(MBOutputStage *s) {
    s->decay_from = s->last_sample;
    s->decay_pos = 0;
    s->last_sample = 0.0f;
}

/// Short linear ramp from the last emitted sample to zero, then zeros: no step, no click.
static void write_silence(MBOutputStage *s, float *out, uint32_t frames) {
    uint32_t decay = (uint32_t)(s->tuning.fade_out_seconds * s->output_rate);
    if (decay == 0) decay = 1;
    for (uint32_t i = 0; i < frames; i++) {
        if (s->decay_pos < decay) {
            s->decay_pos++;
            out[i] = s->decay_from * (1.0f - (float)s->decay_pos / (float)decay);
        } else {
            out[i] = 0.0f;
        }
    }
}

static void apply_epoch(MBOutputStage *s, uint64_t epoch) {
    s->epoch = epoch;
    s->input_rate = b2d(atomic_load_explicit(&s->requested_rate_bits, memory_order_relaxed));
    // Whatever is in the ring was produced at the previous rate.
    mb_ring_discard_to(s->ring, 0);
    if (s->state == MBOutputStateRunning) begin_silence(s);
    s->converter = s->input_rate > MB_FAST_CONVERTER_ABOVE ? 1 : 0;
    s->state = s->input_rate > 0 ? MBOutputStateRefill : MBOutputStateSilent;
    atomic_store_explicit(&s->stat_input_rate_bits, d2b(s->input_rate), memory_order_relaxed);
    atomic_store_explicit(&s->stat_converter, (uint32_t)s->converter, memory_order_relaxed);
}

static double valid_scalar(double scalar) {
    return (scalar >= MB_SCALAR_MIN && scalar <= MB_SCALAR_MAX) ? scalar : 1.0;
}

/// Feeds the resampler only the input it needs for this block (src_process would otherwise copy everything
/// available into its own buffer) and tracks the exact input position of its filter centre: the sum of
/// 1 / ratio over the generated frames, with the same linear ratio ramp as src_process. Unlike the ring's
/// read index, that position does not depend on how much input the resampler happens to hold.
static uint32_t resample(MBOutputStage *s, uint32_t frames, double ratio) {
    SRC_STATE *src = s->converters[s->converter];
    uint32_t produced = 0;
    for (int guard = 0; produced < frames && guard < 64; guard++) {
        uint32_t available;
        const float *in = mb_ring_read_region(s->ring, &available);
        if (available == 0) break;
        uint32_t want = (uint32_t)ceil((double)(frames - produced) / ratio) + 1;
        if (want > available) want = available;

        uint32_t requested = frames - produced;
        SRC_DATA data = {
            .data_in = in,
            .data_out = s->scratch + produced,
            .input_frames = want,
            .output_frames = requested,
            .src_ratio = ratio,
            .end_of_input = 0,
        };
        if (src_process(src, &data) != 0) {
            count(&s->stat_errors);
            break;
        }
        mb_ring_consume(s->ring, (uint32_t)data.input_frames_used);

        // Mirror of src_process: the first call after a reset starts at the requested ratio; then each
        // output frame i of a call uses last + i * (ratio - last) / requested, and the last one is kept.
        double last = s->src_last_ratio < 1.0 / 256.0 ? ratio : s->src_last_ratio;
        double diff = ratio - last;
        int ramp = fabs(diff) > 1e-10;
        double advance = 0.0, r = last;
        for (long i = 0; i < data.output_frames_gen; i++) {
            if (ramp) r = last + (double)i * diff / (double)requested;
            advance += 1.0 / r;
        }
        s->src_last_ratio = data.output_frames_gen > 0 ? r : last;
        s->position += advance;

        produced += (uint32_t)data.output_frames_gen;
        if (data.input_frames_used == 0 && data.output_frames_gen == 0) break;
    }
    return produced;
}

/// Fill as the loop sees it: producer position − filter centre position. The producer's position is
/// extrapolated to this cycle's time from its last write, so the estimate does not jump with the order of
/// the two IO callbacks. Returns -1 when the producer's timing is stale (paused): the loop then holds.
static double estimate_fill(const MBOutputStage *s, double host_seconds, double in_scalar) {
    double write_index = (double)(mb_ring_read_index(s->ring) + mb_ring_fill(s->ring));
    double producer_time = mb_ring_producer_time(s->ring);
    if (host_seconds <= 0 || producer_time <= 0) return write_index - s->position;
    double rate = s->input_rate * in_scalar;
    double block = mb_ring_producer_block(s->ring);
    double age = host_seconds - producer_time;
    double max_age = 3.0 * block / rate + 0.02;
    if (age > max_age || age < -max_age) return -1;
    double virtual_write = (host_seconds - mb_ring_producer_origin(s->ring)) * rate;
    return virtual_write - s->position;
}

static void process_block(MBOutputStage *s, uint32_t frames, double output_scalar, double host_seconds) {
    float *out = s->scratch;
    uint64_t epoch = atomic_load_explicit(&s->requested_epoch, memory_order_acquire);
    if (epoch != s->epoch) apply_epoch(s, epoch);

    uint32_t fill = mb_ring_fill(s->ring);
    uint32_t target = s->state == MBOutputStateSilent ? 0 : target_fill(s, frames);
    atomic_store_explicit(&s->stat_fill, fill, memory_order_relaxed);
    atomic_store_explicit(&s->stat_target, target, memory_order_relaxed);
    double in_scalar = valid_scalar(mb_ring_producer_rate_scalar(s->ring));

    if (s->state == MBOutputStateRefill && fill >= target) {
        src_reset(s->converters[s->converter]);
        s->src_last_ratio = 0.0;
        s->position = (double)mb_ring_read_index(s->ring);   // the first output is centred on the next input
        double estimate = estimate_fill(s, host_seconds, in_scalar);
        if (estimate > target) {
            // Start exactly on target: drop the oldest excess now (we are silent, a fade-in follows) rather
            // than letting the loop slew it away at ±max_correction for tens of seconds.
            uint32_t excess = (uint32_t)(estimate - target);
            mb_ring_discard_to(s->ring, fill > excess ? fill - excess : 0);
            fill = mb_ring_fill(s->ring);
            s->position = (double)mb_ring_read_index(s->ring);
            estimate = estimate_fill(s, host_seconds, in_scalar);
        }
        s->filtered_fill = estimate >= 0 ? estimate : fill;
        s->integral = 0.0;
        s->correction = 0.0;
        s->fade_pos = 0;
        s->state = MBOutputStateRunning;
    }

    if (s->state == MBOutputStateRunning) {
        // Input the next block needs beyond the filter centre, at the most extreme correction.
        double write_index = (double)(mb_ring_read_index(s->ring) + fill);
        double needed_end = s->position + frames * s->input_rate / s->output_rate * (1.0 + s->tuning.max_correction)
                            + half_filter(s) + 2.0;

        if (fill > high_water(s, target)) {
            // The consumer stalled while the producer kept writing; the producer had to drop samples, so the
            // ring holds a discontinuity. Drop everything, fade, refill from fresh input.
            count(&s->stat_overflows);
            mb_ring_discard_to(s->ring, 0);
            begin_silence(s);
            s->state = MBOutputStateRefill;
        } else if (write_index < needed_end) {
            count(&s->stat_underruns);
            // What is left precedes a gap: playing it after the refill would put a step right after the fade-in.
            mb_ring_discard_to(s->ring, 0);
            begin_silence(s);
            s->state = MBOutputStateRefill;
        } else {
            double estimate = estimate_fill(s, host_seconds, in_scalar);
            if (estimate >= 0) atomic_store_explicit(&s->stat_estimated_bits, d2b(estimate), memory_order_relaxed);

            // PI loop on the low-passed fill estimate, in seconds of input. While the producer's timing is
            // stale (paused), hold the last correction.
            double dt = frames / s->output_rate;
            double max = s->tuning.max_correction;
            if (estimate >= 0) {
                if (host_seconds > 0 && mb_ring_producer_time(s->ring) > 0) count(&s->stat_timed);
                double alpha = dt / (s->tuning.fill_filter_seconds + dt);
                s->filtered_fill += alpha * (estimate - s->filtered_fill);
                double error = (s->filtered_fill - target) / s->input_rate;
                double integral = s->integral + error * dt;
                // Anti-windup: the integral term alone never exceeds the correction range.
                if (s->tuning.ki > 0) integral = clampd(integral, -max / s->tuning.ki, max / s->tuning.ki);
                s->integral = integral;
                s->correction = clampd(s->tuning.kp * error + s->tuning.ki * integral, -max, max);
            }
            double correction = s->correction;
            double out_scalar = valid_scalar(output_scalar);
            double ratio = (s->output_rate * out_scalar) / (s->input_rate * in_scalar) * (1.0 - correction);

            uint32_t produced = resample(s, frames, ratio);
            if (produced < frames) {
                // Not expected after the check above; degrade gracefully.
                count(&s->stat_underruns);
                s->last_sample = produced > 0 ? out[produced - 1] : s->last_sample;
                mb_ring_discard_to(s->ring, 0);
                begin_silence(s);
                write_silence(s, out + produced, frames - produced);
                s->state = MBOutputStateRefill;
            }

            uint32_t fade = (uint32_t)(s->tuning.fade_in_seconds * s->output_rate);
            for (uint32_t i = 0; i < produced && s->fade_pos < fade; i++) {
                s->fade_pos++;
                out[i] *= (float)s->fade_pos / (float)fade;
            }
            if (produced == frames) s->last_sample = out[frames - 1];

            atomic_store_explicit(&s->stat_filtered_fill_bits, d2b(s->filtered_fill), memory_order_relaxed);
            atomic_store_explicit(&s->stat_correction_bits, d2b(correction), memory_order_relaxed);
            atomic_store_explicit(&s->stat_ratio_bits, d2b(ratio), memory_order_relaxed);
            atomic_store_explicit(&s->stat_state, (uint32_t)s->state, memory_order_relaxed);
            return;
        }
    }

    write_silence(s, out, frames);
    atomic_store_explicit(&s->stat_state, (uint32_t)s->state, memory_order_relaxed);
}

void mb_output_process(MBOutputStage *s, float *const *destinations, const uint32_t *strides, uint32_t count_dst,
                       uint32_t frames, double output_scalar, double host_seconds) {
    atomic_fetch_add_explicit(&s->stat_cycles, 1, memory_order_relaxed);
    uint32_t offset = 0;
    while (offset < frames) {
        uint32_t n = frames - offset;
        if (n > s->max_frames) n = s->max_frames;
        // Later chunks of a split block happen later in the stream.
        double chunk_time = host_seconds > 0 ? host_seconds + offset / s->output_rate : 0;
        process_block(s, n, output_scalar, chunk_time);
        for (uint32_t d = 0; d < count_dst; d++) {
            float *dst = destinations[d] + (size_t)offset * strides[d];
            uint32_t stride = strides[d];
            for (uint32_t i = 0; i < n; i++) dst[(size_t)i * stride] = s->scratch[i];
        }
        offset += n;
    }
}
