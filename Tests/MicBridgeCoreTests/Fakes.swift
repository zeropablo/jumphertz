import Foundation
@testable import MicBridgeCore

final class FakeBridge: AudioBridge {
    let input: DeviceInfo
    let output: DeviceInfo
    var sampleRate: Double
    var inputChannel: Int
    var started = false
    var stopped = false
    var failOnStart = false
    /// When false, every read of cycleCount advances (IO running). When true the counter is frozen.
    var stalled = false
    private var cycles: UInt64 = 0
    var onEvent: ((BridgeEvent) -> Void)?

    init(input: DeviceInfo, output: DeviceInfo, inputChannel: Int) {
        self.input = input
        self.output = output
        self.inputChannel = inputChannel
        sampleRate = input.sampleRate
    }

    func start() throws {
        if failOnStart { throw ChannelMapError.noOutputChannels }
        started = true
    }
    func stop() { stopped = true }
    func setInputChannel(_ channel: Int) throws { inputChannel = channel }
    func setGain(dB: Double) {}
    func takePeak() -> Float { 0 }
    var cycleCount: UInt64 {
        if !stalled { cycles += 94 }
        return cycles
    }
    var signalCycleCount: UInt64 { 0 }
    var clipCount: UInt64 { 0 }
    var lastCycleFrames: Int { 512 }
    var bufferFrameSize: Int? { 512 }
}

final class FakeSystem: AudioSystem {
    var deviceList: [DeviceInfo]
    var aggregates: [AggregateInfo] = []
    var bridges: [FakeBridge] = []
    /// Number of upcoming starts that fail.
    var failingStarts = 0
    var onDevicesChanged: (() -> Void)?

    init(devices: [DeviceInfo]) { deviceList = devices }

    var live: [FakeBridge] { bridges.filter { $0.started && !$0.stopped } }

    func devices() -> [DeviceInfo] { deviceList }
    func visibleAggregates() -> [AggregateInfo] { aggregates }
    func makeBridge(input: DeviceInfo, output: DeviceInfo, inputChannel: Int, gainDb: Double,
                    bufferFrames: Int?) -> AudioBridge {
        let bridge = FakeBridge(input: input, output: output, inputChannel: inputChannel)
        if failingStarts > 0 {
            bridge.failOnStart = true
            failingStarts -= 1
        }
        bridges.append(bridge)
        return bridge
    }
    func latency(input: DeviceInfo, output: DeviceInfo, bufferFrames: Int?) -> BridgeLatency {
        BridgeLatency(input: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      output: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      sampleRate: 48000)
    }

    /// Replaces a device (by UID) and fires the device-list notification.
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
