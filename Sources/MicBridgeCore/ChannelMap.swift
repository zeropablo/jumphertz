import Foundation

public struct ChannelLocation: Equatable, Sendable {
    public var buffer: Int
    public var channel: Int

    public init(buffer: Int, channel: Int) {
        self.buffer = buffer
        self.channel = channel
    }
}

/// Where to read and write inside the aggregate device's buffer lists, and which streams to enable.
public struct RoutingPlan: Equatable, Sendable {
    public var source: ChannelLocation
    public var destinations: [ChannelLocation]
    public var inputStreamsEnabled: [Bool]
    public var outputStreamsEnabled: [Bool]
}

public enum ChannelMapError: Error, Equatable, CustomStringConvertible {
    case inputChannelOutOfRange(requested: Int, available: Int)
    case layoutMismatch(String)
    case noOutputChannels

    public var description: String {
        switch self {
        case let .inputChannelOutOfRange(requested, available):
            return "Input channel \(requested) does not exist (the interface has \(available) inputs)."
        case let .layoutMismatch(detail):
            return "Unexpected aggregate device layout: \(detail)"
        case .noOutputChannels:
            return "The bridge output device has no output channels."
        }
    }
}

/// Pure channel arithmetic. In an aggregate device, sub-device streams appear in sub-device list order:
/// the input device (index 0) first, then the bridge output device.
public enum ChannelMap {
    /// Locates a zero-based global channel index within a list of per-buffer channel counts.
    public static func locate(globalChannel: Int, channelsPerBuffer: [Int]) -> ChannelLocation? {
        guard globalChannel >= 0 else { return nil }
        var base = 0
        for (index, count) in channelsPerBuffer.enumerated() {
            if globalChannel < base + count { return ChannelLocation(buffer: index, channel: globalChannel - base) }
            base += count
        }
        return nil
    }

    /// - Parameters:
    ///   - aggregateInput / aggregateOutput: channels per buffer of the aggregate's stream configuration.
    ///   - micInputs / micOutputs: channel totals of the input sub-device (placed first).
    ///   - sinkOutputs: output channel total of the bridge output sub-device (placed second).
    ///   - inputChannel: 1-based channel on the input device.
    public static func plan(aggregateInput: [Int], aggregateOutput: [Int],
                            micInputs: Int, micOutputs: Int, sinkOutputs: Int,
                            inputChannel: Int) throws -> RoutingPlan {
        guard inputChannel >= 1, inputChannel <= micInputs else {
            throw ChannelMapError.inputChannelOutOfRange(requested: inputChannel, available: micInputs)
        }
        guard sinkOutputs > 0 else { throw ChannelMapError.noOutputChannels }
        let totalIn = aggregateInput.reduce(0, +)
        let totalOut = aggregateOutput.reduce(0, +)
        guard totalIn >= micInputs else {
            throw ChannelMapError.layoutMismatch("aggregate has \(totalIn) inputs, interface alone has \(micInputs)")
        }
        guard totalOut == micOutputs + sinkOutputs else {
            throw ChannelMapError.layoutMismatch(
                "aggregate has \(totalOut) outputs, expected \(micOutputs) + \(sinkOutputs)")
        }

        guard let source = locate(globalChannel: inputChannel - 1, channelsPerBuffer: aggregateInput) else {
            throw ChannelMapError.layoutMismatch("cannot locate input channel \(inputChannel)")
        }
        let destinationCount = min(2, sinkOutputs)
        let destinations = try (0..<destinationCount).map { offset -> ChannelLocation in
            guard let loc = locate(globalChannel: micOutputs + offset, channelsPerBuffer: aggregateOutput) else {
                throw ChannelMapError.layoutMismatch("cannot locate output channel \(micOutputs + offset + 1)")
            }
            return loc
        }

        // Keep every stream of the input interface enabled so the input channel can change without rebuilding;
        // disable the bridge output's input streams and the interface's output streams.
        let inputEnabled = enabledBuffers(channelsPerBuffer: aggregateInput, range: 0..<micInputs)
        let outputBuffers = Set(destinations.map(\.buffer))
        let outputEnabled = aggregateOutput.indices.map { outputBuffers.contains($0) }

        return RoutingPlan(source: source, destinations: destinations,
                           inputStreamsEnabled: inputEnabled, outputStreamsEnabled: outputEnabled)
    }

    static func enabledBuffers(channelsPerBuffer: [Int], range: Range<Int>) -> [Bool] {
        var base = 0
        return channelsPerBuffer.map { count in
            defer { base += count }
            return count > 0 && base < range.upperBound && base + count > range.lowerBound
        }
    }
}
