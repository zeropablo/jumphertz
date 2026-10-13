import Testing
@testable import MicBridgeCore

struct ChannelMapTests {
    @Test func locateAcrossBuffers() {
        #expect(ChannelMap.locate(globalChannel: 0, channelsPerBuffer: [18, 2]) == ChannelLocation(buffer: 0, channel: 0))
        #expect(ChannelMap.locate(globalChannel: 18, channelsPerBuffer: [18, 2]) == ChannelLocation(buffer: 1, channel: 0))
        #expect(ChannelMap.locate(globalChannel: 3, channelsPerBuffer: [2, 2, 2]) == ChannelLocation(buffer: 1, channel: 1))
        #expect(ChannelMap.locate(globalChannel: 20, channelsPerBuffer: [18, 2]) == nil)
        #expect(ChannelMap.locate(globalChannel: -1, channelsPerBuffer: [18, 2]) == nil)
    }

    /// Scarlett 16i16 (18 in / 16 out, one stream each) + BlackHole 2ch.
    @Test func scarlett16i16PlusBlackHole() throws {
        let plan = try ChannelMap.plan(aggregateInput: [18, 2], aggregateOutput: [16, 2],
                                       micInputs: 18, micOutputs: 16, sinkOutputs: 2, inputChannel: 1)
        #expect(plan.source == ChannelLocation(buffer: 0, channel: 0))
        #expect(plan.destinations == [ChannelLocation(buffer: 1, channel: 0), ChannelLocation(buffer: 1, channel: 1)])
        #expect(plan.inputStreamsEnabled == [true, false])
        #expect(plan.outputStreamsEnabled == [false, true])
    }

    /// Interfaces exposing several streams, and a BlackHole 16ch output.
    @Test func multiStreamInterface() throws {
        let plan = try ChannelMap.plan(aggregateInput: [2, 2, 16], aggregateOutput: [2, 2, 16],
                                       micInputs: 4, micOutputs: 4, sinkOutputs: 16, inputChannel: 3)
        #expect(plan.source == ChannelLocation(buffer: 1, channel: 0))
        #expect(plan.destinations == [ChannelLocation(buffer: 2, channel: 0), ChannelLocation(buffer: 2, channel: 1)])
        #expect(plan.inputStreamsEnabled == [true, true, false])
        #expect(plan.outputStreamsEnabled == [false, false, true])
    }

    @Test func monoOutputGetsOneDestination() throws {
        let plan = try ChannelMap.plan(aggregateInput: [2, 1], aggregateOutput: [2, 1],
                                       micInputs: 2, micOutputs: 2, sinkOutputs: 1, inputChannel: 2)
        #expect(plan.destinations == [ChannelLocation(buffer: 1, channel: 0)])
    }

    @Test func rejectsOutOfRangeChannel() {
        #expect(throws: ChannelMapError.inputChannelOutOfRange(requested: 3, available: 2)) {
            try ChannelMap.plan(aggregateInput: [2, 2], aggregateOutput: [2, 2],
                                micInputs: 2, micOutputs: 2, sinkOutputs: 2, inputChannel: 3)
        }
        #expect(throws: ChannelMapError.inputChannelOutOfRange(requested: 0, available: 2)) {
            try ChannelMap.plan(aggregateInput: [2, 2], aggregateOutput: [2, 2],
                                micInputs: 2, micOutputs: 2, sinkOutputs: 2, inputChannel: 0)
        }
    }

    @Test func rejectsUnexpectedLayout() {
        #expect(throws: ChannelMapError.self) {
            try ChannelMap.plan(aggregateInput: [18, 2], aggregateOutput: [16],
                                micInputs: 18, micOutputs: 16, sinkOutputs: 2, inputChannel: 1)
        }
    }
}
