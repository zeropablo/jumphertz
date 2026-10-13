import Foundation
import Testing
@testable import JumphertzCore

/// Configuration changes applied by the running agent, with the least disruption, and never a device format
/// change while Discord runs.
@MainActor
struct HotReloadTests {
    let system = FakeSystem(devices: [scarlett, scarlettSolo, blackHole, blackHole16])
    let scheduler = ManualScheduler()
    let controller: BridgeController

    init() {
        controller = BridgeController(system: system, permission: FakePermission(.granted), config: .default,
                                      scheduler: scheduler)
    }

    private func startCall() {
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .running)
    }

    private func with(_ change: (inout Config) -> Void) -> Config {
        var config = controller.config
        change(&config)
        return config
    }

    private func expectNoRebuildAndNoFormatChange() {
        #expect(system.outputs.count == 1 && system.inputs.count == 1)
        #expect(controller.counters.inputRebuilds == 0 && controller.counters.outputRebuilds == 0)
        #expect(system.rateChanges.isEmpty)
    }

    @Test func channelAppliedLiveWithoutRebuild() {
        startCall()
        controller.setConfig(with { $0.inputChannel = 4 })
        #expect(system.inputs[0].channelChanges == [4])
        #expect(controller.config.inputChannel == 4)
        expectNoRebuildAndNoFormatChange()
    }

    @Test func gainAppliedLiveWithoutRebuild() {
        startCall()
        controller.setConfig(with { $0.gainDb = -6 })
        #expect(system.inputs[0].gains == [-6])
        expectNoRebuildAndNoFormatChange()
    }

    @Test func channelTheInterfaceDoesNotHaveIsRefusedLive() {
        startCall()
        controller.setConfig(with { $0.inputChannel = 40 })
        #expect(controller.config.inputChannel == 1)            // previous value kept
        #expect(system.inputs[0].inputChannel == 1)
        #expect(controller.allWarnings.contains { $0.contains("inputChannel 40") })
        expectNoRebuildAndNoFormatChange()
    }

    @Test func interfaceChangeRebuildsOnlyTheInput() {
        startCall()
        controller.setConfig(with { $0.deviceUID = "solo" })
        #expect(controller.counters.inputRebuilds == 1)
        #expect(system.liveInputs.first?.device == scarlettSolo)
        #expect(system.outputs.count == 1 && !system.outputs[0].stopped)
        #expect(system.rateChanges.isEmpty)
    }

    @Test func inputBufferChangeRebuildsOnlyTheInput() {
        startCall()
        controller.setConfig(with { $0.bufferFrames = 256 })
        #expect(controller.counters.inputRebuilds == 1)
        #expect(!system.outputs[0].stopped)
    }

    @Test func outputChangeNeverWritesAFormatWhileDiscordRuns() {
        var slow = blackHole16
        slow.sampleRate = 44100
        system.update(blackHole16.uid) { $0 = slow }
        startCall()
        controller.setConfig(with { $0.outputDeviceUID = blackHole16.uid })
        #expect(controller.counters.outputRebuilds == 1)
        #expect(system.liveOutputs.first?.device.uid == blackHole16.uid)
        #expect(system.liveOutputs.first?.sampleRate == 44100)   // followed, not changed
        #expect(system.liveInputs.count == 1)
        #expect(system.rateChanges.isEmpty)

        controller.setDiscordApps([])                            // after the call: standard rate
        #expect(system.rateChanges.map(\.uid) == [blackHole16.uid])
    }

    @Test func latencyLeverChangeRebuildsTheOutputWithoutFormatChange() {
        startCall()
        controller.setConfig(with { $0.outputBufferFrames = 128 })
        #expect(controller.counters.outputRebuilds == 1)
        #expect(system.rateChanges.isEmpty)
    }

    @Test func disablingStopsEverything() {
        startCall()
        controller.setConfig(with { $0.enabled = false })
        #expect(controller.state == .disabled)
        #expect(system.liveOutputs.isEmpty && system.liveInputs.isEmpty)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func changesWhileIdleAllocateNothing() {
        controller.reconcile()
        controller.setConfig(with { $0.inputChannel = 2; $0.gainDb = -3; $0.deviceUID = "solo" })
        #expect(system.outputs.isEmpty && system.inputs.isEmpty)
        #expect(scheduler.pendingCount == 0)
        startCall()
        #expect(system.liveInputs.first?.device == scarlettSolo)
        #expect(system.liveInputs.first?.inputChannel == 2)
    }

    @Test func invalidFileKeepsThePreviousSettingsUntilFixed() {
        startCall()
        controller.setConfig(with { $0.gainDb = -6 })
        controller.rejectConfig(.invalidJSON("unexpected end of file"))
        #expect(controller.config.gainDb == -6)
        #expect(controller.allWarnings.contains { $0.contains("keeping the previous settings") })
        expectNoRebuildAndNoFormatChange()

        controller.setConfig(controller.config)                  // a valid file again (same values)
        #expect(controller.configWarnings.isEmpty)
    }

    @Test func channelTooLargeForTheInterfaceAtStartUsesChannelOne() {
        var config = Config.default
        config.inputChannel = 10
        config.deviceUID = "solo"
        let controller = BridgeController(system: system, permission: FakePermission(.granted), config: config,
                                          scheduler: scheduler)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .running)                    // no error, no retry loop
        #expect(system.liveInputs.first?.inputChannel == 1)
        #expect(controller.allWarnings.contains { $0.contains("inputChannel 10") })
    }
}
