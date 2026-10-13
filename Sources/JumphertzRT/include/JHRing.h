#ifndef JUMPHERTZ_RING_H
#define JUMPHERTZ_RING_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lock-free single-producer / single-consumer ring of mono float samples.
/// Producer = input IOProc (Scarlett clock), consumer = output IOProc (BlackHole clock).
/// Besides the samples it carries what the producer publishes about its stream (block size, rate scalar).
typedef struct JHRing JHRing;

// MARK: Control thread (allocates)

/// `capacity` is rounded up to a power of two.
JHRing *_Nullable jh_ring_create(uint32_t capacity);
void jh_ring_destroy(JHRing *_Nullable ring);
uint32_t jh_ring_capacity(const JHRing *_Nonnull ring);

// MARK: Either side

/// Samples written and not yet consumed. Exact for the consumer, a lower bound of the space for the producer.
uint32_t jh_ring_fill(const JHRing *_Nonnull ring);

// MARK: Producer

/// Writes up to `count` samples, returns how many fit (the rest is the caller's to drop and count).
uint32_t jh_ring_write(JHRing *_Nonnull ring, const float *_Nonnull samples, uint32_t count);
/// Free space as up to two contiguous regions (the second one starts at the beginning of the storage),
/// to write without an intermediate copy. Returns the total free space. Then commit what was written.
uint32_t jh_ring_write_regions(JHRing *_Nonnull ring, float *_Nullable *_Nonnull first, uint32_t *_Nonnull first_count,
                               float *_Nullable *_Nonnull second, uint32_t *_Nonnull second_count);
void jh_ring_commit(JHRing *_Nonnull ring, uint32_t count);
/// Stream information for the consumer, published after each write: block size, HAL rate scalar, and the
/// timing of the write (`host_seconds` = ideal time of the IO cycle, `frame_rate` = actual input rate).
/// From the timing the consumer extrapolates where the producer is "now", which gives a fill level that does
/// not jump with the order of the two IO callbacks. `host_seconds` = 0 publishes no timing.
void jh_ring_publish_block(JHRing *_Nonnull ring, uint32_t frames, double rate_scalar, double host_seconds,
                           double frame_rate);

// MARK: Consumer

/// Contiguous readable region starting at the read position.
const float *_Nonnull jh_ring_read_region(const JHRing *_Nonnull ring, uint32_t *_Nonnull contiguous);
void jh_ring_consume(JHRing *_Nonnull ring, uint32_t count);
/// Drops the oldest samples so that at most `keep` remain.
void jh_ring_discard_to(JHRing *_Nonnull ring, uint32_t keep);
/// Last block size and HAL rate scalar published by the producer (0 / 0 if none yet).
uint32_t jh_ring_producer_block(const JHRing *_Nonnull ring);
double jh_ring_producer_rate_scalar(const JHRing *_Nonnull ring);
/// Time of the producer's last write (0 if none / unknown) and its stream origin: the time at which the write
/// index would have been 0 at the producer's rate. Virtual write index at time T = (T - origin) × rate.
double jh_ring_producer_time(const JHRing *_Nonnull ring);
double jh_ring_producer_origin(const JHRing *_Nonnull ring);
/// Capture origin: host time at which sample index 0 would have been captured by the input device, so that
/// sample i was captured at origin + i / rate. 0 if unknown. Used to measure the bridge's real latency.
void jh_ring_publish_capture_origin(JHRing *_Nonnull ring, double origin_seconds);
double jh_ring_capture_origin(const JHRing *_Nonnull ring);
/// Total samples ever written (write index).
uint64_t jh_ring_write_index(const JHRing *_Nonnull ring);
/// Total samples ever consumed (read index).
uint64_t jh_ring_read_index(const JHRing *_Nonnull ring);

#ifdef __cplusplus
}
#endif

#endif
