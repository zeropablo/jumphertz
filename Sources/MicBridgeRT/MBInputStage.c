#include "MBInputStage.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "MicBridgeRT.h"   // MB_CLIP_THRESHOLD

struct MBInputStage {
    MBRing *ring;
    double input_rate;
    _Atomic uint32_t gain_bits;
    _Atomic uint32_t peak_bits;
    _Atomic uint64_t cycles;
    _Atomic uint64_t signal_cycles;
    _Atomic uint64_t clipped;
    _Atomic uint64_t dropped;
    _Atomic uint32_t last_frames;
    float current_gain;   // IO thread only (and control thread before the first cycle)
};

static inline uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, sizeof u); return u; }
static inline float b2f(uint32_t u) { float f; memcpy(&f, &u, sizeof f); return f; }

MBInputStage *mb_input_create(MBRing *ring, double input_rate) {
    MBInputStage *s = calloc(1, sizeof(MBInputStage));
    if (s == NULL) return NULL;
    s->ring = ring;
    s->input_rate = input_rate;
    atomic_init(&s->gain_bits, f2b(1.0f));
    atomic_init(&s->peak_bits, 0);
    atomic_init(&s->cycles, 0);
    atomic_init(&s->signal_cycles, 0);
    atomic_init(&s->clipped, 0);
    atomic_init(&s->dropped, 0);
    atomic_init(&s->last_frames, 0);
    s->current_gain = 1.0f;
    return s;
}

void mb_input_destroy(MBInputStage *stage) { free(stage); }

void mb_input_set_gain(MBInputStage *s, float gain) {
    if (!isfinite(gain) || gain < 0.0f) gain = 0.0f;
    if (atomic_load_explicit(&s->cycles, memory_order_relaxed) == 0) s->current_gain = gain;
    atomic_store_explicit(&s->gain_bits, f2b(gain), memory_order_release);
}

// Real-time rules: no allocation, no locks, no Objective-C/Swift, no logging, no syscalls.
void mb_input_process(MBInputStage *s, const float *samples, uint32_t stride, uint32_t frames, double rate_scalar,
                      double host_seconds, double capture_seconds) {
    atomic_fetch_add_explicit(&s->cycles, 1, memory_order_relaxed);
    atomic_store_explicit(&s->last_frames, frames, memory_order_relaxed);
    if (frames == 0 || stride == 0) return;

    double scalar = (rate_scalar > 0.99 && rate_scalar < 1.01) ? rate_scalar : 1.0;
    if (capture_seconds > 0) {
        // Index of this block's first frame ↔ its capture time.
        double first_index = (double)mb_ring_write_index(s->ring);
        mb_ring_publish_capture_origin(s->ring, capture_seconds - first_index / (s->input_rate * scalar));
    }

    float *first, *second;
    uint32_t n1, n2;
    uint32_t space = mb_ring_write_regions(s->ring, &first, &n1, &second, &n2);
    uint32_t writable = frames < space ? frames : space;

    float target = b2f(atomic_load_explicit(&s->gain_bits, memory_order_acquire));
    float gain = s->current_gain;
    float step = (target - gain) / (float)frames;
    float peak = 0.0f;
    uint32_t nonzero = 0, clipped = 0;

    for (uint32_t f = 0; f < frames; f++) {
        float in = samples[(size_t)f * stride];
        nonzero |= (in != 0.0f);
        gain += step;
        float x = in * gain;
        float a = fabsf(x);
        if (a >= MB_CLIP_THRESHOLD) {
            clipped++;
            if (a > 1.0f) {
                x = x > 0.0f ? 1.0f : -1.0f;
                a = 1.0f;
            }
        }
        if (a > peak) peak = a;
        if (f < n1) first[f] = x;
        else if (f < writable) second[f - n1] = x;
    }
    s->current_gain = target;
    mb_ring_commit(s->ring, writable);
    mb_ring_publish_block(s->ring, frames, rate_scalar, host_seconds, s->input_rate * scalar);

    if (writable < frames) {
        atomic_fetch_add_explicit(&s->dropped, frames - writable, memory_order_relaxed);
    }
    if (nonzero) atomic_fetch_add_explicit(&s->signal_cycles, 1, memory_order_relaxed);
    if (clipped) atomic_fetch_add_explicit(&s->clipped, clipped, memory_order_relaxed);
    uint32_t bits = f2b(peak);
    if (bits > atomic_load_explicit(&s->peak_bits, memory_order_relaxed)) {
        atomic_store_explicit(&s->peak_bits, bits, memory_order_relaxed);
    }
}

// MARK: Statistics

float mb_input_take_peak(MBInputStage *s) {
    return b2f(atomic_exchange_explicit(&s->peak_bits, 0, memory_order_acq_rel));
}

uint64_t mb_input_cycles(const MBInputStage *s) {
    return atomic_load_explicit(&((MBInputStage *)s)->cycles, memory_order_relaxed);
}

uint64_t mb_input_signal_cycles(const MBInputStage *s) {
    return atomic_load_explicit(&((MBInputStage *)s)->signal_cycles, memory_order_relaxed);
}

uint64_t mb_input_clipped_samples(const MBInputStage *s) {
    return atomic_load_explicit(&((MBInputStage *)s)->clipped, memory_order_relaxed);
}

uint64_t mb_input_dropped_samples(const MBInputStage *s) {
    return atomic_load_explicit(&((MBInputStage *)s)->dropped, memory_order_relaxed);
}

uint32_t mb_input_last_frames(const MBInputStage *s) {
    return atomic_load_explicit(&((MBInputStage *)s)->last_frames, memory_order_relaxed);
}
