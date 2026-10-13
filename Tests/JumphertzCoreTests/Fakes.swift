import Foundation
@testable import JumphertzCore

final class FakeOutputLeg: OutputLeg {
    let device: DeviceInfo
    let sampleRate: Double
    var onEvent: ((BridgeEvent) -> Void)?
    var started = false
    var stopped = false
    var failOnStart = false
    var inputRates: [Double] = []
    var latencyResets = 0
    /// When false, every read of the stats advances the cycle counter (IO running).
    var stalled = false
    var fakeStats = OutputStats()

    init(device: DeviceInfo) {
        self.device = device
        sampleRate = device.sampleRate
    }

    func start() throws {
        if failOnStart { throw ChannelMapError.noOutputChannels }
        started = true
    }
    func stop() { stopped = true }
    func setInputRate(_ rate: Double) { inputRates.append(rate) }
    func resetLatencyWindow() { latencyResets += 1 }
    var stats: OutputStats {
        if !stalled { fakeStats.cycles += 94 }
        return fakeStats
    }
    var bufferFrameSize: Int? { 512 }
    var running: Bool { started && !stopped }
}

final class FakeInputLeg: InputLeg {
    let device: DeviceInfo
    let sampleRate: Double
    var inputChannel: Int
    var onEvent: ((BridgeEvent) -> Void)?
    var started = false
    var stopped = false
    var failOnStart = false
    var stalled = false
    var dropped: UInt64 = 0
    private var cycles: UInt64 = 0
    let output: FakeOutputLeg

    init(device: DeviceInfo, inputChannel: Int, output: FakeOutputLeg) {
        self.device = device
        self.inputChannel = inputChannel
        self.output = output
        sampleRate = device.sampleRate
    }

    func start() throws {
        if failOnStart { throw ChannelMapError.noOutputChannels }
        started = true
        output.setInputRate(sampleRate)
    }
    func stop() {
        stopped = true
        output.setInputRate(0)
    }
    func setInputChannel(_ channel: Int) throws { inputChannel = channel }
    func setGain(dB: Double) {}
    func takePeak() -> Float { 0 }
    var cycleCount: UInt64 {
        if !stalled { cycles += 94 }
        return cycles
    }
    var signalCycleCount: UInt64 { 0 }
    var clipCount: UInt64 { 0 }
    var droppedSamples: UInt64 { dropped }
    var lastCycleFrames: Int { 512 }
    var bufferFrameSize: Int? { 512 }
    var running: Bool { started && !stopped }
}

final class FakeSystem: AudioSystem {
    var deviceList: [DeviceInfo]
    var aggregates: [AggregateInfo] = []
    var outputs: [FakeOutputLeg] = []
    var inputs: [FakeInputLeg] = []
    /// Number of upcoming starts that fail.
    var failingOutputStarts = 0
    var failingInputStarts = 0
    var rateChanges: [(uid: String, rate: Double)] = []
    var onDevicesChanged: (() -> Void)?

    init(devices: [DeviceInfo]) { deviceList = devices }

    var liveOutputs: [FakeOutputLeg] { outputs.filter(\.running) }
    var liveInputs: [FakeInputLeg] { inputs.filter(\.running) }

    func devices() -> [DeviceInfo] { deviceList }
    func visibleAggregates() -> [AggregateInfo] { aggregates }

    func makeOutputLeg(device: DeviceInfo, options: OutputOptions) -> OutputLeg {
        let leg = FakeOutputLeg(device: device)
        if failingOutputStarts > 0 {
            leg.failOnStart = true
            failingOutputStarts -= 1
        }
        outputs.append(leg)
        return leg
    }

    func makeInputLeg(device: DeviceInfo, inputChannel: Int, gainDb: Double, bufferFrames: Int?,
                      output: OutputLeg) -> InputLeg {
        let leg = FakeInputLeg(device: device, inputChannel: inputChannel, output: output as! FakeOutputLeg)
        if failingInputStarts > 0 {
            leg.failOnStart = true
            failingInputStarts -= 1
        }
        inputs.append(leg)
        return leg
    }

    func setNominalSampleRate(_ rate: Double, of device: DeviceInfo) throws {
        rateChanges.append((device.uid, rate))
        update(device.uid) { $0.sampleRate = rate }
    }

    func latencyComponents(input: DeviceInfo, output: DeviceInfo) -> BridgeLatency {
        BridgeLatency(input: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      output: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      sampleRate: 48000)
    }

    func update(_ uid: String, _ change: (inout DeviceInfo) -> Void) {
        if let index = deviceList.firstIndex(where: { $0.uid == uid }) { change(&deviceList[index]) }
    }
}

final class FakePermission: MicPermissionProviding {
    var status: MicPermission
    var requests = 0
    var pending: ((MicPermission) -> Void)?

    init(_ status: MicPermission) { self.status = status }

    func request(_ completion: @escaping (MicPermission) -> Void) {
        requests += 1
        pending = completion
    }

    func answer(_ result: MicPermission) {
        status = result
        pending?(result)
        pending = nil
    }
}

/// Deterministic scheduler: time only moves with advance(by:).
final class ManualScheduler: Scheduler {
    private final class Item: Cancellable {
        let fire: Date
        let order: Int
        let action: () -> Void
        var cancelled = false
        init(fire: Date, order: Int, action: @escaping () -> Void) {
            self.fire = fire
            self.order = order
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var now = Date(timeIntervalSinceReferenceDate: 0)
    private var items: [Item] = []
    private var counter = 0

    var pendingCount: Int { items.filter { !$0.cancelled }.count }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> Cancellable {
        counter += 1
        let item = Item(fire: now.addingTimeInterval(delay), order: counter, action: action)
        items.append(item)
        return item
    }

    func advance(by interval: TimeInterval) {
        let end = now.addingTimeInterval(interval)
        while let next = items.filter({ !$0.cancelled && $0.fire <= end })
            .min(by: { ($0.fire, $0.order) < ($1.fire, $1.order) }) {
            items.removeAll { $0 === next }
            now = max(now, next.fire)
            next.action()
        }
        items.removeAll { $0.cancelled }
        now = end
    }
}

let scarlett = DeviceInfo(id: 10, uid: "scarlett", name: "Scarlett 16i16 4th Gen", manufacturer: "Focusrite",
                          inputChannels: 18, outputChannels: 18, sampleRate: 48000)
let blackHole = DeviceInfo(id: 20, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                           manufacturer: "Existential Audio Inc.", inputChannels: 2, outputChannels: 2,
                           sampleRate: 48000)
