import Testing
@testable import JumphertzCore

struct ChannelMapTests {
    @Test func locateAcrossBuffers() {
        #expect(ChannelMap.locate(globalChannel: 0, channelsPerBuffer: [18, 2]) == ChannelLocation(buffer: 0, channel: 0))
        #expect(ChannelMap.locate(globalChannel: 18, channelsPerBuffer: [18, 2]) == ChannelLocation(buffer: 1, channel: 0))
        #expect(ChannelMap.locate(globalChannel: 3, channelsPerBuffer: [2, 2, 2]) == ChannelLocation(buffer: 1, channel: 1))
        #expect(ChannelMap.locate(globalChannel: 20, channelsPerBuffer: [18, 2]) == nil)
        #expect(ChannelMap.locate(globalChannel: -1, channelsPerBuffer: [18, 2]) == nil)
    }

    /// Scarlett 16i16 4th Gen: one 18-channel input stream.
    @Test func scarlettInput() throws {
        let routing = try ChannelMap.input(layout: [18], inputChannel: 1)
        #expect(routing.source == ChannelLocation(buffer: 0, channel: 0))
        #expect(routing.inputStreamsEnabled == [true])
        #expect(try ChannelMap.input(layout: [18], inputChannel: 18).source == ChannelLocation(buffer: 0, channel: 17))
    }

    /// Interfaces exposing several streams keep them all on (channel switch without rebuild).
    @Test func multiStreamInput() throws {
        let routing = try ChannelMap.input(layout: [2, 2, 4], inputChannel: 3)
        #expect(routing.source == ChannelLocation(buffer: 1, channel: 0))
        #expect(routing.inputStreamsEnabled == [true, true, true])
    }

    @Test func rejectsOutOfRangeChannel() {
        #expect(throws: ChannelMapError.inputChannelOutOfRange(requested: 3, available: 2)) {
            try ChannelMap.input(layout: [2], inputChannel: 3)
        }
        #expect(throws: ChannelMapError.inputChannelOutOfRange(requested: 0, available: 2)) {
            try ChannelMap.input(layout: [2], inputChannel: 0)
        }
    }

    @Test func blackHoleOutputs() throws {
        let stereo = try ChannelMap.output(layout: [2])
        #expect(stereo.destinations == [ChannelLocation(buffer: 0, channel: 0), ChannelLocation(buffer: 0, channel: 1)])
        #expect(stereo.outputStreamsEnabled == [true])

        let wide = try ChannelMap.output(layout: [16])      // BlackHole 16ch: channels 1 + 2
        #expect(wide.destinations == [ChannelLocation(buffer: 0, channel: 0), ChannelLocation(buffer: 0, channel: 1)])

        let split = try ChannelMap.output(layout: [1, 1, 2])
        #expect(split.destinations == [ChannelLocation(buffer: 0, channel: 0), ChannelLocation(buffer: 1, channel: 0)])
        #expect(split.outputStreamsEnabled == [true, true, false])
    }

    @Test func monoAndEmptyOutputs() throws {
        #expect(try ChannelMap.output(layout: [1]).destinations == [ChannelLocation(buffer: 0, channel: 0)])
        #expect(throws: ChannelMapError.noOutputChannels) { try ChannelMap.output(layout: []) }
    }
}
