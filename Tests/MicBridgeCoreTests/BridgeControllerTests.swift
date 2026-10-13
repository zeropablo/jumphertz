import Foundation
import Testing
@testable import MicBridgeCore

private final class FakeBridge: AudioBridge {
    let input: DeviceInfo
    let output: DeviceInfo
    var sampleRate: Double { 48000 }
    var inputChannel: Int
    var started = false
    var stopped = false
    var failOnStart = false

    init(input: DeviceInfo, output: DeviceInfo, inputChannel: Int) {
        self.input = input
        self.output = output
        self.inputChannel = inputChannel
    }

    func start() throws {
        if failOnStart { throw ChannelMapError.noOutputChannels }
        started = true
    }
    func stop() { stopped = true }
    func setInputChannel(_ channel: Int) throws { inputChannel = channel }
    func setGain(dB: Double) {}
    func takePeak() -> Float { 0 }
    var cycleCount: UInt64 { 0 }
    var signalCycleCount: UInt64 { 0 }
    var clipCount: UInt64 { 0 }
    var lastCycleFrames: Int { 512 }
    var bufferFrameSize: Int? { 512 }
}

private final class FakeSystem: AudioSystem {
    var deviceList: [DeviceInfo]
    var aggregates: [AggregateInfo] = []
    var bridges: [FakeBridge] = []
    var failNextStart = false

    init(devices: [DeviceInfo]) { deviceList = devices }

    func devices() -> [DeviceInfo] { deviceList }
    func visibleAggregates() -> [AggregateInfo] { aggregates }
    func makeBridge(input: DeviceInfo, output: DeviceInfo, inputChannel: Int, gainDb: Double,
                    bufferFrames: Int?) -> AudioBridge {
        let bridge = FakeBridge(input: input, output: output, inputChannel: inputChannel)
        bridge.failOnStart = failNextStart
        failNextStart = false
        bridges.append(bridge)
        return bridge
    }
    func latency(input: DeviceInfo, output: DeviceInfo, bufferFrames: Int?) -> BridgeLatency {
        BridgeLatency(input: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      output: .init(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 0),
                      sampleRate: 48000)
    }
}

private final class FakePermission: MicPermissionProviding {
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

private let scarlett = DeviceInfo(id: 10, uid: "scarlett", name: "Scarlett 16i16 4th Gen", manufacturer: "Focusrite",
                                  inputChannels: 18, outputChannels: 18, sampleRate: 48000)
private let blackHole = DeviceInfo(id: 20, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                                   manufacturer: "Existential Audio Inc.", inputChannels: 2, outputChannels: 2,
                                   sampleRate: 48000)

/// The controller runs on the main thread in the agent; these tests drive it synchronously.
@MainActor
struct BridgeControllerTests {
    private func make(permission: MicPermission = .granted, devices: [DeviceInfo] = [scarlett, blackHole],
                      config: Config = .default) -> (BridgeController, FakeSystem, FakePermission) {
        let system = FakeSystem(devices: devices)
        let perm = FakePermission(permission)
        return (BridgeController(system: system, permission: perm, config: config), system, perm)
    }

    @Test func idleWithoutDiscord() {
        let (controller, system, _) = make()
        controller.reconcile()
        #expect(controller.state == .idle)
        #expect(system.bridges.isEmpty)
    }

    @Test func discordLaunchStartsAndQuitStopsBridge() throws {
        let (controller, system, _) = make()
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .running)
        let bridge = try #require(system.bridges.first)
        #expect(bridge.started && bridge.input == scarlett && bridge.output == blackHole)

        controller.setDiscordApps([])
        #expect(controller.state == .idle)
        #expect(bridge.stopped)
        #expect(controller.bridge == nil)
    }

    @Test func secondDiscordVariantKeepsSingleBridge() {
        let (controller, system, _) = make()
        controller.setDiscordApps(["com.hnc.Discord"])
        controller.setDiscordApps(["com.hnc.Discord", "com.hnc.DiscordPTB"])
        #expect(system.bridges.count == 1)
        controller.setDiscordApps(["com.hnc.DiscordPTB"])
        #expect(controller.state == .running)
        #expect(system.bridges.count == 1 && !system.bridges[0].stopped)
    }

    @Test func disabledConfigNeverBridges() {
        var config = Config.default
        config.enabled = false
        let (controller, system, _) = make(config: config)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .disabled)
        #expect(system.bridges.isEmpty)
    }

    @Test func permissionRequestedBeforeTouchingAudio() {
        let (controller, system, permission) = make(permission: .notDetermined)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .waitingForPermission)
        #expect(permission.requests == 1)
        #expect(system.bridges.isEmpty)

        controller.reconcile()   // no duplicate prompt while one is pending
        #expect(permission.requests == 1)

        permission.answer(.granted)
        #expect(controller.state == .running)
        #expect(system.bridges.count == 1)
    }

    @Test func deniedPermissionStaysIdleWithoutBridge() {
        let (controller, system, _) = make(permission: .denied)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .permissionDenied)
        #expect(system.bridges.isEmpty)
    }

    @Test func missingDevicesWait() {
        let (controller, _, _) = make(devices: [blackHole])
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .waitingForDevices)

        let (controller2, _, _) = make(devices: [scarlett])
        controller2.setDiscordApps(["com.hnc.Discord"])
        #expect(controller2.state == .waitingForDevices)
    }

    @Test func startFailureReportsError() {
        let (controller, system, _) = make()
        system.failNextStart = true
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .error)
        #expect(controller.bridge == nil)
    }

    @Test func feedbackWarningExposed() {
        let (controller, system, _) = make()
        system.aggregates = [AggregateInfo(uid: "m", name: "Enceintes", isMultiOutput: true,
                                           subDeviceUIDs: ["speakers", blackHole.uid])]
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.warnings.count == 1)
        #expect(controller.warnings[0].contains("Enceintes"))
    }

    @Test func discordBundleIDs() {
        #expect(DiscordApps.isDiscord(bundleID: "com.hnc.Discord"))
        #expect(DiscordApps.isDiscord(bundleID: "com.hnc.DiscordCanary"))
        #expect(!DiscordApps.isDiscord(bundleID: "com.hnc.Discord.helper"))
        #expect(!DiscordApps.isDiscord(bundleID: nil))
    }
}
