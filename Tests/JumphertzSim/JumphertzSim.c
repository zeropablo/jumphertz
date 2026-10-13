#include "JumphertzSim.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

JHSimConfig jh_sim_default_config(void) {
    JHSimConfig c;
    memset(&c, 0, sizeof c);
    c.input_rate = 44100;
    c.output_rate = 48000;
    c.input_block = 512;
    c.output_block = 512;
    c.jitter = 0.2;
    c.seconds = 10;
    c.tone_hz = 1000;
    c.amplitude = 0.5;
    c.settle_seconds = 30;
    c.tuning = jh_output_default_tuning();
    return c;
}

static uint32_t lcg(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

static double uniform(uint32_t *state) { return (lcg(state) >> 8) / 16777216.0 - 0.5; }

/// Simulated host clock offset: real mHostTime values are never close to 0 (0 means "unknown" in the stages).
#define HOST_EPOCH 1000.0

static int in_window(double t, double at, double length) { return length > 0 && t >= at && t < at + length; }

int jh_sim_run(const JHSimConfig *c, JHSimResult *r) {
    memset(r, 0, sizeof *r);
    r->fill_min = UINT32_MAX;
    r->correction_min_ppm = 1e9;
    r->estimate_min = 1e18;
    r->estimate_max = -1e18;
    r->correction_max_ppm = -1e9;

    JHRing *ring = jh_ring_create(32768);
    JHInputStage *input = jh_input_create(ring, c->input_rate);
    uint32_t max_block = c->output_block > 4096 ? c->output_block : 4096;
    JHOutputStage *output = jh_output_create(ring, c->output_rate, max_block, c->tuning);
    float *in_block = calloc(c->input_block, sizeof(float));
    float *out_block = calloc(c->output_block, sizeof(float));
    if (!ring || !input || !output || !in_block || !out_block) return -1;

    double input_rate = c->input_rate;
    double in_true = input_rate * (1 + c->input_ppm * 1e-6);
    double out_true = c->output_rate * (1 + c->output_ppm * 1e-6);
    double in_scalar = c->pass_rate_scalars ? 1 + c->input_ppm * 1e-6 : 0;
    double out_scalar = c->pass_rate_scalars ? 1 + c->output_ppm * 1e-6 : 0;
    jh_output_set_input_rate(output, input_rate);

    uint32_t seed = 12345;
    uint64_t in_k = 0, out_k = 0;            // block counters (reset for the input after a rate change)
    double in_origin = 0;                    // true time of the input clock's block 0
    uint64_t in_sample = 0;                  // samples produced since the input clock (re)started
    double phase_origin = 0;                 // tone phase at in_origin
    double in_jit = uniform(&seed) * c->jitter, out_jit = uniform(&seed) * c->jitter;
    int rate_changed = 0, input_stopped_for_change = 0, latency_reset = 0;

    float last = 0;
    int have_last = 0;
    uint64_t gap = 0;
    double sum1 = 0, sum2 = 0;
    double rx = 0, ry = 0, rxx = 0, rxy = 0;
    uint64_t rn = 0;
    uint64_t n1 = 0, n2 = 0;
    double steady_end = c->seconds;
    double steady_mid = c->settle_seconds + (steady_end - c->settle_seconds) / 2;
    uint64_t steady_in_start = 0, steady_out_start = 0, steady_fill_start = 0;
    int steady_started = 0;
    uint64_t consumed_at_steady = 0;
    uint64_t produced_total = 0;

    for (;;) {
        double in_period = c->input_block / in_true;
        double out_period = c->output_block / out_true;
        double t_in = in_origin + (in_k + 1) * in_period + in_jit * in_period;
        double t_out = (out_k + 1) * out_period + out_jit * out_period;
        double t = t_in < t_out ? t_in : t_out;
        if (t >= c->seconds) break;

        // Input side rebuild at another rate: stop, announce silence, then the new stream.
        if (c->rate_change_gap > 0 && !rate_changed && t >= c->rate_change_at) {
            if (!input_stopped_for_change) {
                jh_output_set_input_rate(output, 0);
                input_stopped_for_change = 1;
            }
            if (t >= c->rate_change_at + c->rate_change_gap) {
                input_rate = c->new_input_rate;
                // The input side is rebuilt: a new stage at the new rate, as the agent will do.
                jh_input_destroy(input);
                input = jh_input_create(ring, input_rate);
                in_true = input_rate * (1 + c->input_ppm * 1e-6);
                double tone_phase = 2 * M_PI * c->tone_hz * t;   // physical tone keeps running
                phase_origin = tone_phase;
                in_origin = t;
                in_k = 0;
                in_sample = 0;
                jh_output_set_input_rate(output, input_rate);
                rate_changed = 1;
                continue;
            }
        }

        if (t_in <= t_out) {
            in_k++;
            in_jit = uniform(&seed) * c->jitter;
            int paused = in_window(t, c->producer_pause_at, c->producer_pause_seconds)
                || (input_stopped_for_change && !rate_changed);
            if (!paused) {
                for (uint32_t i = 0; i < c->input_block; i++) {
                    double tt = (double)(in_sample + i) / in_true;
                    in_block[i] = (float)(c->amplitude * sin(phase_origin + 2 * M_PI * c->tone_hz * tt));
                }
                // HAL timestamps are ideal cycle times on a host clock that is far from 0.
                double ideal = HOST_EPOCH + in_origin + in_k * in_period;
                // The block was captured during the period that ends at this cycle.
                double captured = ideal - c->input_block / in_true;
                jh_input_process(input, in_block, 1, c->input_block, in_scalar, ideal, captured);
                produced_total += c->input_block;
                r->input_frames += c->input_block;
            }
            in_sample += c->input_block;
        } else {
            out_k++;
            out_jit = uniform(&seed) * c->jitter;
            if (in_window(t, c->consumer_pause_at, c->consumer_pause_seconds)) continue;

            float *dst[1] = {out_block};
            uint32_t stride[1] = {1};
            // Written now, presented one block later.
            double ideal = HOST_EPOCH + out_k * out_period;
            jh_output_process(output, dst, stride, 1, c->output_block, out_scalar, ideal, ideal + out_period);
            if (!latency_reset && t >= c->settle_seconds) {
                jh_output_reset_latency(output);
                latency_reset = 1;
            }
            JHOutputStats st;
            jh_output_get_stats(output, &st);
            int running = st.state == JHOutputStateRunning;

            for (uint32_t i = 0; i < c->output_block; i++) {
                float x = out_block[i];
                if (!isfinite(x)) r->non_finite++;
                if (have_last) {
                    double step = fabs((double)x - last);
                    if (step > r->max_step) {
                        r->max_step = step;
                        r->max_step_at = t;
                    }
                }
                last = x;
                have_last = 1;
                if (c->capture && t >= c->capture_from && r->captured < c->capture_capacity) {
                    c->capture[r->captured++] = x;
                }
            }
            r->output_frames += c->output_block;

            if (!running) gap += c->output_block;
            else {
                if (gap > r->longest_gap) r->longest_gap = gap;
                gap = 0;
            }

            int disturbed = in_window(t, c->producer_pause_at, c->producer_pause_seconds + 5)
                || in_window(t, c->consumer_pause_at, c->consumer_pause_seconds + 5)
                || (c->rate_change_gap > 0 && in_window(t, c->rate_change_at, c->rate_change_gap + 5));
            if (t >= c->settle_seconds && !disturbed) {
                if (!running) r->silent_frames_after_settle += c->output_block;
                if (st.fill < r->fill_min) r->fill_min = st.fill;
                if (st.fill > r->fill_max) r->fill_max = st.fill;
                if (st.correction_ppm < r->correction_min_ppm) r->correction_min_ppm = st.correction_ppm;
                if (st.correction_ppm > r->correction_max_ppm) r->correction_max_ppm = st.correction_ppm;
                r->target_fill = st.target_fill;
                if (st.estimated_fill < r->estimate_min) r->estimate_min = st.estimated_fill;
                if (st.estimated_fill > r->estimate_max) r->estimate_max = st.estimated_fill;
                // Least squares of fill over time.
                rx += t; ry += st.estimated_fill; rxx += t * t; rxy += t * st.estimated_fill; rn++;
                if (t < steady_mid) { sum1 += st.fill; n1++; } else { sum2 += st.fill; n2++; }
                if (!steady_started) {
                    steady_started = 1;
                    steady_in_start = produced_total;
                    steady_out_start = r->output_frames;
                    steady_fill_start = st.fill;
                    consumed_at_steady = produced_total - st.fill;
                }
            }
        }
    }
    if (gap > r->longest_gap) r->longest_gap = gap;

    JHOutputStats st;
    jh_output_get_stats(output, &st);
    r->underruns = st.underruns;
    r->overflows = st.overflows;
    r->resampler_errors = st.resampler_errors;
    r->dropped = jh_input_dropped_samples(input);
    r->fill_mean_first_half = n1 ? sum1 / n1 : 0;
    r->fill_mean_second_half = n2 ? sum2 / n2 : 0;

    if (rn > 2) {
        double slope = (rn * rxy - rx * ry) / (rn * rxx - rx * rx);   // frames per second
        r->fill_slope_ppm = slope / in_true * 1e6;
    }
    r->timed_cycles = st.timed_cycles;
    r->latency_min = st.latency_min;
    r->latency_mean = st.latency_mean;
    r->latency_max = st.latency_max;
    (void)steady_in_start;
    (void)steady_out_start;
    (void)steady_fill_start;
    (void)consumed_at_steady;

    free(in_block);
    free(out_block);
    jh_output_destroy(output);
    jh_input_destroy(input);
    jh_ring_destroy(ring);
    return 0;
}

// MARK: - Analysis

double jh_analysis_thdn(const float *x, uint64_t n, double rate, double f) {
    double ss = 0, cc = 0, sc = 0, ys = 0, yc = 0, ym = 0;
    for (uint64_t i = 0; i < n; i++) {
        double s = sin(2 * M_PI * f * i / rate), c = cos(2 * M_PI * f * i / rate);
        ss += s * s; cc += c * c; sc += s * c; ys += x[i] * s; yc += x[i] * c; ym += x[i];
    }
    double det = ss * cc - sc * sc;
    double a = (ys * cc - yc * sc) / det, b = (yc * ss - ys * sc) / det;
    double err = 0, pow = 0;
    for (uint64_t i = 0; i < n; i++) {
        double m = a * sin(2 * M_PI * f * i / rate) + b * cos(2 * M_PI * f * i / rate);
        err += (x[i] - m) * (x[i] - m);
        pow += m * m;
    }
    (void)ym;
    return 10 * log10(err / pow);
}

double jh_analysis_tone_level(const float *x, uint64_t n, double rate, double f) {
    double w = 2 * M_PI * f / rate, coeff = 2 * cos(w), s1 = 0, s2 = 0, wsum = 0;
    for (uint64_t i = 0; i < n; i++) {
        double hann = 0.5 - 0.5 * cos(2 * M_PI * i / (n - 1));
        wsum += hann;
        double s0 = x[i] * hann + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    double amplitude = 2 * sqrt(power) / wsum;
    return 20 * log10(amplitude + 1e-30);
}

/// Phase of `x[0..n)` against a carrier at `f` that started at sample index `offset`.
static double phase_at(const float *x, uint64_t n, uint64_t offset, double rate, double f) {
    double re = 0, im = 0;
    for (uint64_t i = 0; i < n; i++) {
        double hann = 0.5 - 0.5 * cos(2 * M_PI * i / (n - 1));
        double carrier = 2 * M_PI * f * (double)(i + offset) / rate;
        re += x[i] * hann * cos(carrier);
        im -= x[i] * hann * sin(carrier);
    }
    return atan2(im, re);
}

double jh_analysis_frequency(const float *x, uint64_t n, double rate, double guess) {
    // Phase of the first and second half measured at the guessed frequency; the phase advance gives the
    // deviation from the guess. Valid while the deviation is well below rate / n.
    uint64_t half = n / 2;
    double p1 = phase_at(x, half, 0, rate, guess);
    double p2 = phase_at(x + half, half, half, rate, guess);
    double dp = p2 - p1;
    while (dp > M_PI) dp -= 2 * M_PI;
    while (dp < -M_PI) dp += 2 * M_PI;
    return guess + dp / (2 * M_PI * (half / rate));
}

double jh_analysis_windowed_thdn(const float *x, uint64_t n, double rate, double guess, uint64_t window,
                                 double *mean_frequency, double *max_deviation_ppm) {
    double worst = -400, sum = 0;
    double frequencies[1024];
    uint64_t count = 0;
    for (uint64_t start = 0; start + window <= n && count < 1024; start += window) {
        double f = jh_analysis_frequency(x + start, window, rate, guess);
        double thdn = jh_analysis_thdn(x + start, window, rate, f);
        if (thdn > worst) worst = thdn;
        frequencies[count++] = f;
        sum += f;
    }
    double mean = count ? sum / count : 0, deviation = 0;
    for (uint64_t i = 0; i < count; i++) {
        double d = fabs(frequencies[i] / mean - 1) * 1e6;
        if (d > deviation) deviation = d;
    }
    *mean_frequency = mean;
    *max_deviation_ppm = deviation;
    return worst;
}

// MARK: - Threaded ring stress

typedef struct {
    JHRing *ring;
    uint64_t total;
    uint32_t seed;
    _Atomic uint64_t errors;
} StressContext;

static void *stress_producer(void *arg) {
    StressContext *s = arg;
    uint32_t seed = s->seed;
    float chunk[1024];
    uint64_t next = 0;
    while (next < s->total) {
        uint32_t want = 1 + lcg(&seed) % 1024;
        if (want > s->total - next) want = (uint32_t)(s->total - next);
        for (uint32_t i = 0; i < want; i++) chunk[i] = (float)((next + i) & 0xFFFFFF);
        uint32_t written = jh_ring_write(s->ring, chunk, want);
        next += written;
    }
    return NULL;
}

static void *stress_consumer(void *arg) {
    StressContext *s = arg;
    uint32_t seed = s->seed ^ 0x9E3779B9u;
    uint64_t expected = 0;
    while (expected < s->total) {
        uint32_t available;
        const float *p = jh_ring_read_region(s->ring, &available);
        if (available == 0) continue;
        uint32_t take = 1 + lcg(&seed) % 1024;
        if (take > available) take = available;
        for (uint32_t i = 0; i < take; i++) {
            if (p[i] != (float)((expected + i) & 0xFFFFFF)) atomic_fetch_add(&s->errors, 1);
        }
        jh_ring_consume(s->ring, take);
        expected += take;
    }
    return NULL;
}

uint64_t jh_ring_stress(uint64_t total, uint32_t capacity, uint32_t seed) {
    StressContext s = {.ring = jh_ring_create(capacity), .total = total, .seed = seed};
    atomic_init(&s.errors, 0);
    pthread_t producer, consumer;
    pthread_create(&producer, NULL, stress_producer, &s);
    pthread_create(&consumer, NULL, stress_consumer, &s);
    pthread_join(producer, NULL);
    pthread_join(consumer, NULL);
    jh_ring_destroy(s.ring);
    return atomic_load(&s.errors);
}
