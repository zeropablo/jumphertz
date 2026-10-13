import Foundation

public struct ChannelLocation: Equatable, Sendable {
    public var buffer: Int
    public var channel: Int

    public init(buffer: Int, channel: Int) {
        self.buffer = buffer
        self.channel = channel
    }
}

public enum ChannelMapError: Error, Equatable, CustomStringConvertible {
    case inputChannelOutOfRange(requested: Int, available: Int)
    case noOutputChannels

    public var description: String {
        switch self {
        case let .inputChannelOutOfRange(requested, available):
            return "Input channel \(requested) does not exist (the interface has \(available) inputs)."
        case .noOutputChannels:
            return "The bridge output device has no output channels."
        }
    }
}

/// Where each IOProc reads or writes inside its own device's buffer list, and which streams it needs.
public struct InputRouting: Equatable, Sendable {
    public var source: ChannelLocation
    /// Every input stream stays on, so the channel can change without rebuilding.
    public var inputStreamsEnabled: [Bool]
}

public struct OutputRouting: Equatable, Sendable {
    /// First two channels (mono → L + R), or one on a mono device.
    public var destinations: [ChannelLocation]
    public var outputStreamsEnabled: [Bool]
}

/// Pure channel arithmetic on a device's stream configuration (channels per buffer).
public enum ChannelMap {
    /// Locates a zero-based channel index within a list of per-buffer channel counts.
    public static func locate(globalChannel: Int, channelsPerBuffer: [Int]) -> ChannelLocation? {
        guard globalChannel >= 0 else { return nil }
        var base = 0
        for (index, count) in channelsPerBuffer.enumerated() {
            if globalChannel < base + count { return ChannelLocation(buffer: index, channel: globalChannel - base) }
            base += count
        }
        return nil
    }

    /// - Parameter inputChannel: 1-based.
    public static func input(layout: [Int], inputChannel: Int) throws -> InputRouting {
        let available = layout.reduce(0, +)
        guard inputChannel >= 1, let source = locate(globalChannel: inputChannel - 1, channelsPerBuffer: layout) else {
            throw ChannelMapError.inputChannelOutOfRange(requested: inputChannel, available: available)
        }
        return InputRouting(source: source, inputStreamsEnabled: layout.map { $0 > 0 })
    }

    public static func output(layout: [Int]) throws -> OutputRouting {
        let available = layout.reduce(0, +)
        guard available > 0 else { throw ChannelMapError.noOutputChannels }
        let destinations = (0..<min(2, available)).compactMap { locate(globalChannel: $0, channelsPerBuffer: layout) }
        let used = Set(destinations.map(\.buffer))
        return OutputRouting(destinations: destinations, outputStreamsEnabled: layout.indices.map { used.contains($0) })
    }
}
