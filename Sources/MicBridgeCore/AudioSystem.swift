import Foundation

/// Hardware notifications concerning a running leg. Delivered on the main queue.
public enum BridgeEvent: Equatable, Sendable {
    case sampleRateChanged(uid: String, rate: Double)
    /// Channel layout / stream format changed.
    case formatChanged(uid: String)
    case deviceDied(uid: String)
    /// An IO cycle missed its deadline (kAudioDeviceProcessorOverload).
    case overload(uid: String)
}

/// Options of the output (BlackHole) leg. Both latency levers are off by default (safest settings).
public struct OutputOptions: Equatable, Sendable {
    /// IO buffer size requested for MicBridge's own IOProc on the output device. nil = untouched.
    public var bufferFrames: Int?
    /// Smaller jitter margin in the ring (lower latency).
    public var reducedMargin: Bool

    public init(bufferFrames: Int? = nil, reducedMargin: Bool = false) {
        self.bufferFrames = bufferFrames
        self.reducedMargin = reducedMargin
    }
}

/// Snapshot of the output leg's resampling stage.
public struct OutputStats: Equatable, Sendable, Codable {
    public enum State: String, Codable, Sendable { case silent, refill, running }

    public var state: State = .silent
    public var inputRate: Double = 0
    public var outputRate: Double = 0
    /// Input frames: raw ring fill, the loop's fill estimate, its target.
    public var fill: Int = 0
    public var estimatedFill: Double = 0
    public var targetFill: Int = 0
    public var correctionPPM: Double = 0
    public var cycles: UInt64 = 0
    public var underruns: UInt64 = 0
    public var overflows: UInt64 = 0
    public var resamplerErrors: UInt64 = 0
    /// Measured from HAL timestamps (capture → presentation in the output device), seconds, current window.
    public var latencyMean: Double = 0
    public var latencyMin: Double = 0
    public var latencyMax: Double = 0
    public var latencyCount: UInt64 = 0

    public init() {}
}

/// MicBridge's IOProc on the output device (BlackHole). Lives as long as Discord runs; never changes the
/// device's format. Owns the ring the input leg writes into.
public protocol OutputLeg: AnyObject {
    var device: DeviceInfo { get }
    /// The device's rate when the leg started (read, never written).
    var sampleRate: Double { get }
    var onEvent: ((BridgeEvent) -> Void)? { get set }
    func start() throws
    /// Idempotent. Stop the input leg first.
    func stop()
    /// Rate of what the input leg writes from now on (0 = no input).
    func setInputRate(_ rate: Double)
    func resetLatencyWindow()
    var stats: OutputStats { get }
    var bufferFrameSize: Int? { get }
}

/// MicBridge's IOProc on the interface (Scarlett). Rebuilt on its own when the interface changes.
public protocol InputLeg: AnyObject {
    var device: DeviceInfo { get }
    /// The interface's rate when the leg started (read, never written).
    var sampleRate: Double { get }
    var inputChannel: Int { get }
    var onEvent: ((BridgeEvent) -> Void)? { get set }
    func start() throws
    /// Idempotent.
    func stop()
    /// Lock-free, applied on the next IO cycle.
    func setInputChannel(_ channel: Int) throws
    /// Lock-free, ramped over one buffer.
    func setGain(dB: Double)
    /// Peak absolute sample (post-gain) since the previous call.
    func takePeak() -> Float
    var cycleCount: UInt64 { get }
    var signalCycleCount: UInt64 { get }
    var clipCount: UInt64 { get }
    /// Samples that did not fit in the ring.
    var droppedSamples: UInt64 { get }
    var lastCycleFrames: Int { get }
    var bufferFrameSize: Int? { get }
}

/// Abstraction over the audio hardware so the control logic can be tested without CoreAudio.
public protocol AudioSystem: AnyObject {
    /// Device list changed (hot plug, driver reload). Main queue.
    var onDevicesChanged: (() -> Void)? { get set }
    func devices() -> [DeviceInfo]
    func visibleAggregates() -> [AggregateInfo]
    func makeOutputLeg(device: DeviceInfo, options: OutputOptions) -> OutputLeg
    /// The input leg writes into `output`'s ring and announces its rate to it.
    func makeInputLeg(device: DeviceInfo, inputChannel: Int, gainDb: Double, bufferFrames: Int?,
                      output: OutputLeg) -> InputLeg
    /// Only ever called on the output device, and only while Discord is not running.
    func setNominalSampleRate(_ rate: Double, of device: DeviceInfo) throws
    /// Static latencies reported by the HAL (device, safety offset, stream, buffer).
    func latencyComponents(input: DeviceInfo, output: DeviceInfo) -> BridgeLatency
}
