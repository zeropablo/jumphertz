import Foundation
import Testing
@testable import MicBridgeCore

/// Phase 3: recovery from sample rate changes, hot plug, sleep, failures and IO stalls.
@MainActor
struct RecoveryTests {
    let system = FakeSystem(devices: [scarlett, blackHole])
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

    @Test func idleAgentSchedulesNothing() {
        controller.reconcile()
        system.onDevicesChanged?()
        #expect(scheduler.pendingCount == 0)
        #expect(system.bridges.isEmpty)
    }

    @Test func onlyTheWatchdogRunsDuringACall() {
        startCall()
        #expect(scheduler.pendingCount == 1)
        controller.setDiscordApps([])
        #expect(scheduler.pendingCount == 0)
    }

    @Test func sampleRateChangeRebuildsAtNewRateAfterDebounce() throws {
        startCall()
        system.update("scarlett") { $0.sampleRate = 44100 }
        let first = try #require(system.bridges.first)
        first.onEvent?(.sampleRateChanged(device: "Scarlett", rate: 44100))

        scheduler.advance(by: 0.4)
        #expect(system.bridges.count == 1)        // still debouncing

        scheduler.advance(by: 0.2)
        #expect(first.stopped)
        #expect(system.live.count == 1)
        #expect(system.live[0].sampleRate == 44100)
        #expect(controller.state == .running)
        #expect(controller.rebuildCount == 1)
        let recovery = try #require(controller.lastRecovery)
        #expect(recovery.milliseconds == 500)
        #expect(recovery.reason.contains("48000 → 44100"))
    }

    @Test func burstOfEventsGivesOneRebuild() throws {
        startCall()
        let first = try #require(system.bridges.first)
        system.update("scarlett") { $0.sampleRate = 44100 }
        for _ in 0..<5 {
            first.onEvent?(.sampleRateChanged(device: "Scarlett", rate: 44100))
            system.onDevicesChanged?()
            scheduler.advance(by: 0.1)
        }
        scheduler.advance(by: 1)
        #expect(system.bridges.count == 2)
        #expect(controller.rebuildCount == 1)
    }

    @Test func ownRateAlignmentDoesNotRebuild() {
        startCall()
        // BlackHole switching to the rate we asked for, or our own private aggregate appearing.
        system.onDevicesChanged?()
        system.bridges[0].onEvent?(.sampleRateChanged(device: "BlackHole 2ch", rate: 48000))
        scheduler.advance(by: 1)
        #expect(system.bridges.count == 1)
        #expect(controller.rebuildCount == 0)
    }

    @Test func unplugWaitsThenReplugRecovers() throws {
        startCall()
        system.deviceList.removeAll { $0.uid == "scarlett" }
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(system.live.isEmpty)
        #expect(controller.state == .waitingForDevices)
        #expect(scheduler.pendingCount == 0)       // no polling while unplugged

        scheduler.advance(by: 30)
        var replugged = scarlett
        replugged.id = 99                          // new AudioObjectID after re-enumeration
        system.deviceList.append(replugged)
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(controller.state == .running)
        #expect(system.live.first?.input.id == 99)
        #expect(try #require(controller.lastRecovery).milliseconds == 500)
    }

    @Test func fastReplugWithinDebounceRebuilds() {
        startCall()
        system.update("scarlett") { $0.id = 77 }
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(system.live.first?.input.id == 77)
        #expect(controller.rebuildCount == 1)
    }

    @Test func deadDeviceRebuildsOrWaits() {
        startCall()
        system.update("BlackHole2ch_UID") { $0.isAlive = false }
        system.bridges[0].onEvent?(.deviceDied(device: "BlackHole 2ch"))
        scheduler.advance(by: 0.6)
        #expect(controller.state == .waitingForDevices)
        #expect(system.live.isEmpty)
    }

    @Test func sleepReleasesAndWakeRebuilds() throws {
        startCall()
        controller.setSuspended(true)
        #expect(controller.state == .suspended)
        #expect(system.live.isEmpty)
        #expect(scheduler.pendingCount == 0)

        scheduler.advance(by: 3600)
        controller.setSuspended(false)
        #expect(controller.state == .running)
        #expect(system.live.count == 1)
        #expect(try #require(controller.lastRecovery).reason == "wake from sleep")
    }

    @Test func wakeBeforeDevicesReappearWaitsForThem() {
        startCall()
        controller.setSuspended(true)
        system.deviceList.removeAll { $0.uid == "scarlett" }
        controller.setSuspended(false)
        #expect(controller.state == .waitingForDevices)

        system.deviceList.append(scarlett)
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(controller.state == .running)
        #expect(controller.lastRecovery?.reason == "wake from sleep")
    }

    @Test func failedStartIsRetriedWithBackoff() {
        system.failingStarts = 2
        startCallExpectingError()
        scheduler.advance(by: 0.5)
        #expect(controller.state == .error)       // second failure
        scheduler.advance(by: 0.9)
        #expect(controller.state == .error)       // next attempt after 1 s, not yet
        scheduler.advance(by: 0.2)
        #expect(controller.state == .running)
        #expect(system.bridges.count == 3)
    }

    private func startCallExpectingError() {
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .error)
    }

    @Test func retriesStopWhenDiscordQuits() {
        system.failingStarts = 100
        startCallExpectingError()
        controller.setDiscordApps([])
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 60)
        #expect(system.bridges.count == 1)
    }

    @Test func watchdogRebuildsStalledIO() throws {
        startCall()
        scheduler.advance(by: 5)
        #expect(controller.rebuildCount == 0)       // IO running: no action

        system.bridges[0].stalled = true
        scheduler.advance(by: 1.0)
        scheduler.advance(by: 1.0)
        scheduler.advance(by: 1.0)
        #expect(controller.rebuildCount == 1)
        #expect(system.live.count == 1)
        #expect(system.live[0] !== system.bridges[0])
        #expect(try #require(controller.lastRecovery).reason == "IO stalled")
    }

    @Test func overloadIsCountedNotRebuilt() {
        startCall()
        system.bridges[0].onEvent?(.overload)
        system.bridges[0].onEvent?(.overload)
        scheduler.advance(by: 1)
        #expect(controller.overloadCount == 2)
        #expect(controller.rebuildCount == 0)
    }
}
