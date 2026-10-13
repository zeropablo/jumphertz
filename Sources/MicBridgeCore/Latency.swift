import Foundation

/// Latency components of one side of the bridge, in frames.
public struct LatencyComponents: Equatable, Sendable {
    public var deviceLatency: Int
    public var safetyOffset: Int
    public var streamLatency: Int
    public var bufferFrames: Int

    public init(deviceLatency: Int, safetyOffset: Int, streamLatency: Int, bufferFrames: Int) {
        self.deviceLatency = deviceLatency
        self.safetyOffset = safetyOffset
        self.streamLatency = streamLatency
        self.bufferFrames = bufferFrames
    }

    public var total: Int { deviceLatency + safetyOffset + streamLatency + bufferFrames }
}

/// Estimated latency added by the bridge: interface input path + bridge output path.
/// Discord's own buffering and processing come on top and are not included.
public struct BridgeLatency: Equatable, Sendable {
    public var input: LatencyComponents
    public var output: LatencyComponents
    public var sampleRate: Double

    public init(input: LatencyComponents, output: LatencyComponents, sampleRate: Double) {
        self.input = input
        self.output = output
        self.sampleRate = sampleRate
    }

    public var totalFrames: Int { input.total + output.total }

    public static func milliseconds(_ frames: Int, sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(frames) / sampleRate * 1000 : 0
    }

    public var totalMilliseconds: Double { Self.milliseconds(totalFrames, sampleRate: sampleRate) }
}
