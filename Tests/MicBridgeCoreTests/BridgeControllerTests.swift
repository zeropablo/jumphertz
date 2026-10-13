import Foundation
import Testing
@testable import MicBridgeCore

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
        system.failingStarts = 1
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
