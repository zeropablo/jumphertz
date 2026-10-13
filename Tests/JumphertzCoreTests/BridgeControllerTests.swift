import Foundation
import Testing
@testable import JumphertzCore

/// The controller runs on the main thread in the agent; these tests drive it synchronously.
@MainActor
struct BridgeControllerTests {
    private func make(permission: MicPermission = .granted, devices: [DeviceInfo] = [scarlett, blackHole],
                      config: Config = .default) -> (BridgeController, FakeSystem, FakePermission) {
        let system = FakeSystem(devices: devices)
        let perm = FakePermission(permission)
        let controller = BridgeController(system: system, permission: perm, config: config,
                                          scheduler: ManualScheduler())
        return (controller, system, perm)
    }

    @Test func idleWithoutDiscord() {
        let (controller, system, _) = make()
        controller.reconcile()
        #expect(controller.state == .idle)
        #expect(system.outputs.isEmpty && system.inputs.isEmpty)
    }

    @Test func discordLaunchStartsBothLegsAndQuitStopsThem() throws {
        let (controller, system, _) = make()
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .running)
        let output = try #require(system.liveOutputs.first)
        let input = try #require(system.liveInputs.first)
        #expect(output.device == blackHole && input.device == scarlett)
        #expect(output.inputRates == [48000])

        controller.setDiscordApps([])
        #expect(controller.state == .idle)
        #expect(input.stopped && output.stopped)
        #expect(controller.output == nil && controller.input == nil)
    }

    @Test func secondDiscordVariantKeepsTheLegs() {
        let (controller, system, _) = make()
        controller.setDiscordApps(["com.hnc.Discord"])
        controller.setDiscordApps(["com.hnc.Discord", "com.hnc.DiscordPTB"])
        controller.setDiscordApps(["com.hnc.DiscordPTB"])
        #expect(controller.state == .running)
        #expect(system.outputs.count == 1 && system.inputs.count == 1)
        #expect(system.liveOutputs.count == 1)
    }

    @Test func disabledConfigNeverBridges() {
        var config = Config.default
        config.enabled = false
        let (controller, system, _) = make(config: config)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .disabled)
        #expect(system.outputs.isEmpty)
    }

    @Test func permissionRequestedBeforeTouchingAudio() {
        let (controller, system, permission) = make(permission: .notDetermined)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .waitingForPermission)
        #expect(permission.requests == 1)
        #expect(system.outputs.isEmpty)

        controller.reconcile()   // no duplicate prompt while one is pending
        #expect(permission.requests == 1)

        permission.answer(.granted)
        #expect(controller.state == .running)
    }

    @Test func deniedPermissionStaysIdleWithoutLegs() {
        let (controller, system, _) = make(permission: .denied)
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .permissionDenied)
        #expect(system.outputs.isEmpty)
    }

    @Test func missingBlackHoleWaitsWithoutLegs() {
        let (controller, system, _) = make(devices: [scarlett])
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .waitingForDevices)
        #expect(system.outputs.isEmpty)
    }

    /// Without an interface, Discord still gets an uninterrupted (silent) BlackHole stream.
    @Test func missingScarlettKeepsTheOutputRunning() {
        let (controller, system, _) = make(devices: [blackHole])
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .waitingForDevices)
        #expect(system.liveOutputs.count == 1)
        #expect(system.inputs.isEmpty)
    }

    @Test func inputStartFailureKeepsTheOutputRunning() {
        let (controller, system, _) = make()
        system.failingInputStarts = 1
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .error)
        #expect(system.liveOutputs.count == 1)
        #expect(controller.input == nil)
    }

    @Test func feedbackWarningExposed() {
        let (controller, system, _) = make()
        system.aggregates = [AggregateInfo(uid: "m", name: "Enceintes", isMultiOutput: true,
                                           subDeviceUIDs: ["speakers", blackHole.uid])]
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.warnings.contains { $0.contains("Enceintes") })
    }

    // MARK: Output device rate

    @Test func outputSetTo48kOnlyWhileDiscordIsNotRunning() {
        var slow = blackHole
        slow.sampleRate = 44100
        let (controller, system, _) = make(devices: [scarlett, slow])
        controller.reconcile()                                      // agent start, no Discord
        #expect(system.rateChanges.map(\.rate) == [48000])
        #expect(system.rateChanges.first?.uid == blackHole.uid)

        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(system.liveOutputs.first?.sampleRate == 48000)
        #expect(system.rateChanges.count == 1)
    }

    @Test func outputRateLeftAloneWhenDiscordAlreadyRuns() {
        var slow = blackHole
        slow.sampleRate = 44100
        let (controller, system, _) = make(devices: [scarlett, slow])
        controller.setDiscordApps(["com.hnc.Discord"])             // Discord already there at agent start
        #expect(system.rateChanges.isEmpty)
        #expect(system.liveOutputs.first?.sampleRate == 44100)
        #expect(controller.warnings.contains { $0.contains("44100 Hz") })

        controller.setDiscordApps([])                               // after the call: back to 48 kHz
        #expect(system.rateChanges.map(\.rate) == [48000])
    }

    @Test func discordBundleIDs() {
        #expect(DiscordApps.isDiscord(bundleID: "com.hnc.Discord"))
        #expect(DiscordApps.isDiscord(bundleID: "com.hnc.DiscordCanary"))
        #expect(!DiscordApps.isDiscord(bundleID: "com.hnc.Discord.helper"))
        #expect(!DiscordApps.isDiscord(bundleID: nil))
    }
}
