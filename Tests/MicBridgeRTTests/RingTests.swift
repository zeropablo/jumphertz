import Testing
import MicBridgeRT
import MicBridgeSim

struct RingTests {
    @Test func capacityIsRoundedToPowerOfTwo() throws {
        let ring = try #require(mb_ring_create(5))
        defer { mb_ring_destroy(ring) }
        #expect(mb_ring_capacity(ring) == 8)
    }

    @Test func writeReadWrapAndDiscard() throws {
        let ring = try #require(mb_ring_create(8))
        defer { mb_ring_destroy(ring) }

        #expect(mb_ring_write(ring, [1, 2, 3, 4, 5, 6], 6) == 6)
        #expect(mb_ring_fill(ring) == 6)
        mb_ring_consume(ring, 4)
        #expect(mb_ring_fill(ring) == 2)

        // 6 more: 2 at the end of the storage, 4 wrapped to the start; then the ring is full.
        #expect(mb_ring_write(ring, [7, 8, 9, 10, 11, 12], 6) == 6)
        #expect(mb_ring_write(ring, [99], 1) == 0)
        #expect(mb_ring_fill(ring) == 8)

        var contiguous: UInt32 = 0
        var region = mb_ring_read_region(ring, &contiguous)
        #expect(contiguous == 4)                       // 5, 6, 7, 8 up to the end of the storage
        #expect(Array(UnsafeBufferPointer(start: region, count: Int(contiguous))) == [5, 6, 7, 8])
        mb_ring_consume(ring, contiguous)
        region = mb_ring_read_region(ring, &contiguous)
        #expect(Array(UnsafeBufferPointer(start: region, count: Int(contiguous))) == [9, 10, 11, 12])

        mb_ring_discard_to(ring, 1)
        region = mb_ring_read_region(ring, &contiguous)
        #expect(contiguous == 1 && region.pointee == 12)
    }

    @Test func producerMetadata() throws {
        let ring = try #require(mb_ring_create(16))
        defer { mb_ring_destroy(ring) }
        mb_ring_publish_block(ring, 512, 1.0001, 10.0, 48000)
        #expect(mb_ring_producer_time(ring) == 10.0)
        #expect(mb_ring_producer_origin(ring) == 10.0)     // nothing written yet: index 0 at t = 10 s
        #expect(mb_ring_producer_block(ring) == 512)
        #expect(mb_ring_producer_rate_scalar(ring) == 1.0001)
    }

    /// Two real threads, random chunk sizes, small ring so that it is constantly full / empty / wrapping.
    @Test func twoThreadStress() {
        #expect(mb_ring_stress(10_000_000, 1024, 42) == 0)
        #expect(mb_ring_stress(2_000_000, 64, 7) == 0)
    }
}
