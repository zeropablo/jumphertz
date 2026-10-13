#ifndef MICBRIDGE_RING_H
#define MICBRIDGE_RING_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lock-free single-producer / single-consumer ring of mono float samples.
/// Producer = input IOProc (Scarlett clock), consumer = output IOProc (BlackHole clock).
/// Besides the samples it carries what the producer publishes about its stream (block size, rate scalar).
typedef struct MBRing MBRing;

// MARK: Control thread (allocates)

/// `capacity` is rounded up to a power of two.
MBRing *_Nullable mb_ring_create(uint32_t capacity);
void mb_ring_destroy(MBRing *_Nullable ring);
uint32_t mb_ring_capacity(const MBRing *_Nonnull ring);

// MARK: Either side

/// Samples written and not yet consumed. Exact for the consumer, a lower bound of the space for the producer.
uint32_t mb_ring_fill(const MBRing *_Nonnull ring);

// MARK: Producer

/// Writes up to `count` samples, returns how many fit (the rest is the caller's to drop and count).
uint32_t mb_ring_write(MBRing *_Nonnull ring, const float *_Nonnull samples, uint32_t count);
/// Free space as up to two contiguous regions (the second one starts at the beginning of the storage),
/// to write without an intermediate copy. Returns the total free space. Then commit what was written.
uint32_t mb_ring_write_regions(MBRing *_Nonnull ring, float *_Nullable *_Nonnull first, uint32_t *_Nonnull first_count,
                               float *_Nullable *_Nonnull second, uint32_t *_Nonnull second_count);
void mb_ring_commit(MBRing *_Nonnull ring, uint32_t count);
/// Stream information for the consumer, published after each write: block size, HAL rate scalar, and the
/// timing of the write (`host_seconds` = ideal time of the IO cycle, `frame_rate` = actual input rate).
/// From the timing the consumer extrapolates where the producer is "now", which gives a fill level that does
/// not jump with the order of the two IO callbacks. `host_seconds` = 0 publishes no timing.
void mb_ring_publish_block(MBRing *_Nonnull ring, uint32_t frames, double rate_scalar, double host_seconds,
                           double frame_rate);

// MARK: Consumer

/// Contiguous readable region starting at the read position.
const float *_Nonnull mb_ring_read_region(const MBRing *_Nonnull ring, uint32_t *_Nonnull contiguous);
void mb_ring_consume(MBRing *_Nonnull ring, uint32_t count);
/// Drops the oldest samples so that at most `keep` remain.
void mb_ring_discard_to(MBRing *_Nonnull ring, uint32_t keep);
/// Last block size and HAL rate scalar published by the producer (0 / 0 if none yet).
uint32_t mb_ring_producer_block(const MBRing *_Nonnull ring);
double mb_ring_producer_rate_scalar(const MBRing *_Nonnull ring);
/// Time of the producer's last write (0 if none / unknown) and its stream origin: the time at which the write
/// index would have been 0 at the producer's rate. Virtual write index at time T = (T - origin) × rate.
double mb_ring_producer_time(const MBRing *_Nonnull ring);
double mb_ring_producer_origin(const MBRing *_Nonnull ring);
/// Capture origin: host time at which sample index 0 would have been captured by the input device, so that
/// sample i was captured at origin + i / rate. 0 if unknown. Used to measure the bridge's real latency.
void mb_ring_publish_capture_origin(MBRing *_Nonnull ring, double origin_seconds);
double mb_ring_capture_origin(const MBRing *_Nonnull ring);
/// Total samples ever written (write index).
uint64_t mb_ring_write_index(const MBRing *_Nonnull ring);
/// Total samples ever consumed (read index).
uint64_t mb_ring_read_index(const MBRing *_Nonnull ring);

#ifdef __cplusplus
}
#endif

#endif
