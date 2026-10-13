import Foundation

/// A running bridge: input channel of `input` copied to the first two outputs of `output`.
public protocol AudioBridge: AnyObject {
    var input: DeviceInfo { get }
    var output: DeviceInfo { get }
    var sampleRate: Double { get }
    var inputChannel: Int { get }

    func start() throws
    /// Idempotent. Stops IO and destroys the underlying device.
    func stop()
    /// Lock-free, applied on the next IO cycle.
    func setInputChannel(_ channel: Int) throws
    /// Lock-free, ramped over one buffer.
    func setGain(dB: Double)
    /// Peak absolute output sample since the previous call.
    func takePeak() -> Float
    var cycleCount: UInt64 { get }
    var signalCycleCount: UInt64 { get }
    /// Output samples at or beyond full scale since start.
    var clipCount: UInt64 { get }
    /// Frames handled by the last IO cycle (0 before the first cycle).
    var lastCycleFrames: Int { get }
    /// Current IO buffer size of the aggregate, as reported by the HAL.
    var bufferFrameSize: Int? { get }
}

/// Abstraction over the audio hardware so the control logic can be tested without CoreAudio.
public protocol AudioSystem: AnyObject {
    func devices() -> [DeviceInfo]
    func visibleAggregates() -> [AggregateInfo]
    func makeBridge(input: DeviceInfo, output: DeviceInfo, inputChannel: Int, gainDb: Double,
                    bufferFrames: Int?) -> AudioBridge
    func latency(input: DeviceInfo, output: DeviceInfo, bufferFrames: Int?) -> BridgeLatency
}
