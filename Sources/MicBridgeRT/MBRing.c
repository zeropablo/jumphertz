#include "MBRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Indices grow monotonically (64 bits never wrap in practice); position = index & mask.
// Producer: reads read_index (acquire) → writes samples → stores write_index (release).
// Consumer: reads write_index (acquire) → reads samples → stores read_index (release).
struct MBRing {
    float *data;
    uint32_t capacity;
    uint32_t mask;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint32_t producer_block;
    _Atomic uint64_t producer_rate_scalar_bits;
    _Atomic uint64_t producer_time_bits;
    _Atomic uint64_t producer_origin_bits;
    _Atomic uint64_t capture_origin_bits;
};

MBRing *mb_ring_create(uint32_t capacity) {
    uint32_t cap = 1;
    while (cap < capacity && cap < (1u << 30)) cap <<= 1;
    MBRing *ring = calloc(1, sizeof(MBRing));
    if (ring == NULL) return NULL;
    ring->data = calloc(cap, sizeof(float));
    if (ring->data == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = cap;
    ring->mask = cap - 1;
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->producer_block, 0);
    atomic_init(&ring->producer_rate_scalar_bits, 0);
    atomic_init(&ring->producer_time_bits, 0);
    atomic_init(&ring->producer_origin_bits, 0);
    atomic_init(&ring->capture_origin_bits, 0);
    return ring;
}

void mb_ring_destroy(MBRing *ring) {
    if (ring == NULL) return;
    free(ring->data);
    free(ring);
}

uint32_t mb_ring_capacity(const MBRing *ring) { return ring->capacity; }

uint32_t mb_ring_fill(const MBRing *ring) {
    uint64_t r = atomic_load_explicit(&((MBRing *)ring)->read_index, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&((MBRing *)ring)->write_index, memory_order_acquire);
    uint64_t fill = w - r;
    return fill > ring->capacity ? ring->capacity : (uint32_t)fill;
}

// MARK: Producer

uint32_t mb_ring_write_regions(MBRing *ring, float **first, uint32_t *first_count, float **second,
                               uint32_t *second_count) {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    uint32_t space = ring->capacity - (uint32_t)(w - r);
    uint32_t pos = (uint32_t)w & ring->mask;
    uint32_t until_end = ring->capacity - pos;
    *first = ring->data + pos;
    *first_count = space < until_end ? space : until_end;
    *second = ring->data;
    *second_count = space - *first_count;
    return space;
}

void mb_ring_commit(MBRing *ring, uint32_t count) {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    atomic_store_explicit(&ring->write_index, w + count, memory_order_release);
}

uint32_t mb_ring_write(MBRing *ring, const float *samples, uint32_t count) {
    float *first, *second;
    uint32_t n1, n2;
    uint32_t space = mb_ring_write_regions(ring, &first, &n1, &second, &n2);
    uint32_t n = count < space ? count : space;
    uint32_t a = n < n1 ? n : n1;
    memcpy(first, samples, a * sizeof(float));
    if (n > a) memcpy(second, samples + a, (n - a) * sizeof(float));
    mb_ring_commit(ring, n);
    return n;
}

static inline uint64_t d2b(double d) { uint64_t u; memcpy(&u, &d, sizeof u); return u; }
static inline double b2d(uint64_t u) { double d; memcpy(&d, &u, sizeof d); return d; }

void mb_ring_publish_block(MBRing *ring, uint32_t frames, double rate_scalar, double host_seconds, double frame_rate) {
    atomic_store_explicit(&ring->producer_block, frames, memory_order_relaxed);
    atomic_store_explicit(&ring->producer_rate_scalar_bits, d2b(rate_scalar), memory_order_relaxed);
    if (host_seconds > 0 && frame_rate > 0) {
        uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
        // One value carries both the index and its time, so the consumer never mixes two writes.
        atomic_store_explicit(&ring->producer_origin_bits, d2b(host_seconds - (double)w / frame_rate),
                              memory_order_relaxed);
        atomic_store_explicit(&ring->producer_time_bits, d2b(host_seconds), memory_order_relaxed);
    } else {
        atomic_store_explicit(&ring->producer_time_bits, d2b(0), memory_order_relaxed);
    }
}

// MARK: Consumer

const float *mb_ring_read_region(const MBRing *ring, uint32_t *contiguous) {
    MBRing *mut = (MBRing *)ring;
    uint64_t r = atomic_load_explicit(&mut->read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&mut->write_index, memory_order_acquire);
    uint32_t fill = (uint32_t)(w - r);
    uint32_t pos = (uint32_t)r & ring->mask;
    uint32_t until_end = ring->capacity - pos;
    *contiguous = fill < until_end ? fill : until_end;
    return ring->data + pos;
}

void mb_ring_consume(MBRing *ring, uint32_t count) {
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    atomic_store_explicit(&ring->read_index, r + count, memory_order_release);
}

void mb_ring_discard_to(MBRing *ring, uint32_t keep) {
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    if (w - r > keep) atomic_store_explicit(&ring->read_index, w - keep, memory_order_release);
}

uint32_t mb_ring_producer_block(const MBRing *ring) {
    return atomic_load_explicit(&((MBRing *)ring)->producer_block, memory_order_relaxed);
}

double mb_ring_producer_rate_scalar(const MBRing *ring) {
    return b2d(atomic_load_explicit(&((MBRing *)ring)->producer_rate_scalar_bits, memory_order_relaxed));
}

double mb_ring_producer_time(const MBRing *ring) {
    return b2d(atomic_load_explicit(&((MBRing *)ring)->producer_time_bits, memory_order_relaxed));
}

double mb_ring_producer_origin(const MBRing *ring) {
    return b2d(atomic_load_explicit(&((MBRing *)ring)->producer_origin_bits, memory_order_relaxed));
}

uint64_t mb_ring_read_index(const MBRing *ring) {
    return atomic_load_explicit(&((MBRing *)ring)->read_index, memory_order_relaxed);
}

void mb_ring_publish_capture_origin(MBRing *ring, double origin_seconds) {
    atomic_store_explicit(&ring->capture_origin_bits, d2b(origin_seconds), memory_order_relaxed);
}

double mb_ring_capture_origin(const MBRing *ring) {
    return b2d(atomic_load_explicit(&((MBRing *)ring)->capture_origin_bits, memory_order_relaxed));
}

uint64_t mb_ring_write_index(const MBRing *ring) {
    return atomic_load_explicit(&((MBRing *)ring)->write_index, memory_order_acquire);
}
