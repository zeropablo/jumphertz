import Foundation
import Testing
@testable import JumphertzCore

/// Recovery with two legs: interface changes rebuild the input leg only; the BlackHole leg (Discord's stream)
/// keeps running and its format is never touched while Discord runs.
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

    private var output: FakeOutputLeg { system.outputs[0] }

    private func expectOutputUntouched() {
        #expect(system.outputs.count == 1)
        #expect(!output.stopped)
        #expect(system.rateChanges.isEmpty)
        #expect(controller.counters.outputFormatChangesWhileDiscordRunning == 0)
    }

    @Test func idleAgentSchedulesNothing() {
        controller.reconcile()
        system.onDevicesChanged?()
        #expect(scheduler.pendingCount == 0)
        #expect(system.outputs.isEmpty)
    }

    /// Invariant (most of the time, Discord is not running): once Discord quits, nothing is left —
    /// no leg, no timer, no periodic status — and hardware events do not wake anything up.
    @Test func idleAfterACallIsCompletelyQuiet() {
        startCall()
        scheduler.advance(by: 10)
        let staleOutput = output
        let staleInput = system.inputs[0]
        controller.setDiscordApps([])

        var changes = 0
        controller.onChange = { _ in changes += 1 }
        #expect(controller.output == nil && controller.input == nil)
        #expect(system.liveOutputs.isEmpty && system.liveInputs.isEmpty)
        #expect(scheduler.pendingCount == 0)

        // Device churn and late callbacks from the stopped legs.
        system.onDevicesChanged?()
        system.update("scarlett") { $0.sampleRate = 44100 }
        staleOutput.onEvent?(.overload(uid: blackHole.uid))
        staleInput.onEvent?(.sampleRateChanged(uid: "scarlett", rate: 44100))
        scheduler.advance(by: 3600)

        #expect(scheduler.pendingCount == 0)
        #expect(changes == 0)
        #expect(system.outputs.count == 1 && system.inputs.count == 1)
        #expect(controller.counters.inputRebuilds == 0)
    }

    @Test func onlyTheTickRunsDuringACall() {
        startCall()
        #expect(scheduler.pendingCount == 1)
        controller.setDiscordApps([])
        #expect(scheduler.pendingCount == 0)
    }

    @Test func interfaceRateChangeRebuildsOnlyTheInput() throws {
        startCall()
        system.update("scarlett") { $0.sampleRate = 44100 }
        system.inputs[0].onEvent?(.sampleRateChanged(uid: "scarlett", rate: 44100))

        scheduler.advance(by: 0.4)
        #expect(system.inputs.count == 1)                       // still debouncing
        scheduler.advance(by: 0.2)
        #expect(system.inputs[0].stopped)
        #expect(system.liveInputs.first?.sampleRate == 44100)
        expectOutputUntouched()
        #expect(output.inputRates == [48000, 0, 44100])        // silence, then the new stream
        #expect(controller.counters.inputRebuilds == 1)
        let recovery = try #require(controller.lastRecovery)
        #expect(recovery.milliseconds == 500)
        #expect(recovery.reason.contains("48000 → 44100"))
    }

    /// Hardware protocol case: opening a 44.1 kHz Logic project three times in a row during a call.
    @Test func threeLogicProjectOpenings() {
        startCall()
        for (index, rate) in [44100.0, 48000, 44100, 48000, 44100, 48000].enumerated() {
            system.update("scarlett") { $0.sampleRate = rate }
            system.liveInputs.first?.onEvent?(.sampleRateChanged(uid: "scarlett", rate: rate))
            scheduler.advance(by: 0.6)
            #expect(controller.state == .running)
            #expect(system.liveInputs.first?.sampleRate == rate)
            #expect(controller.counters.inputRebuilds == index + 1)
        }
        expectOutputUntouched()
    }

    @Test func burstOfEventsGivesOneRebuild() {
        startCall()
        system.update("scarlett") { $0.sampleRate = 44100 }
        for _ in 0..<5 {
            system.liveInputs.first?.onEvent?(.sampleRateChanged(uid: "scarlett", rate: 44100))
            system.onDevicesChanged?()
            scheduler.advance(by: 0.1)
        }
        scheduler.advance(by: 1)
        #expect(controller.counters.inputRebuilds == 1)
        #expect(system.inputs.count == 2)
    }

    @Test func eventsWithoutRealChangeDoNotRebuild() {
        startCall()
        system.onDevicesChanged?()
        output.onEvent?(.sampleRateChanged(uid: blackHole.uid, rate: 48000))
        scheduler.advance(by: 1)
        #expect(controller.counters.inputRebuilds == 0)
        expectOutputUntouched()
    }

    @Test func unplugKeepsTheOutputAndReplugRecovers() throws {
        startCall()
        system.deviceList.removeAll { $0.uid == "scarlett" }
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(system.liveInputs.isEmpty)
        #expect(controller.state == .waitingForDevices)
        expectOutputUntouched()

        scheduler.advance(by: 30)
        var replugged = scarlett
        replugged.id = 99                                       // new AudioObjectID after re-enumeration
        system.deviceList.append(replugged)
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(controller.state == .running)
        #expect(system.liveInputs.first?.device.id == 99)
        #expect(try #require(controller.lastRecovery).milliseconds == 500)
        expectOutputUntouched()
    }

    @Test func fastReplugWithinDebounceRebuildsTheInput() {
        startCall()
        system.update("scarlett") { $0.id = 77 }
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(system.liveInputs.first?.device.id == 77)
        expectOutputUntouched()
    }

    /// Someone else (Audio MIDI Setup, a DAW, a Multi-Output Device) changes BlackHole during a call:
    /// counted, logged, and the output leg follows the new rate without writing it.
    @Test func externalOutputFormatChangeIsCountedAndFollowed() {
        startCall()
        system.update(blackHole.uid) { $0.sampleRate = 44100 }
        output.onEvent?(.sampleRateChanged(uid: blackHole.uid, rate: 44100))
        scheduler.advance(by: 0.6)
        #expect(controller.counters.outputFormatChangesWhileDiscordRunning == 1)
        #expect(controller.counters.outputRebuilds == 1)
        #expect(system.liveOutputs.first?.sampleRate == 44100)
        #expect(system.rateChanges.isEmpty)
        #expect(controller.state == .running)
    }

    @Test func blackHoleRemovedStopsBothLegs() {
        startCall()
        system.deviceList.removeAll { $0.uid == blackHole.uid }
        output.onEvent?(.deviceDied(uid: blackHole.uid))
        scheduler.advance(by: 0.6)
        #expect(system.liveOutputs.isEmpty && system.liveInputs.isEmpty)
        #expect(controller.state == .waitingForDevices)
        #expect(controller.counters.outputFormatChangesWhileDiscordRunning == 0)
    }

    @Test func sleepReleasesAndWakeRebuilds() throws {
        startCall()
        controller.setSuspended(true)
        #expect(controller.state == .suspended)
        #expect(system.liveOutputs.isEmpty && system.liveInputs.isEmpty)
        #expect(scheduler.pendingCount == 0)

        scheduler.advance(by: 3600)
        controller.setSuspended(false)
        #expect(controller.state == .running)
        #expect(try #require(controller.lastRecovery).reason == "wake from sleep")
        #expect(system.rateChanges.isEmpty)
    }

    @Test func wakeBeforeTheInterfaceReappears() {
        startCall()
        controller.setSuspended(true)
        system.deviceList.removeAll { $0.uid == "scarlett" }
        controller.setSuspended(false)
        #expect(controller.state == .waitingForDevices)
        #expect(system.liveOutputs.count == 1)

        system.deviceList.append(scarlett)
        system.onDevicesChanged?()
        scheduler.advance(by: 0.6)
        #expect(controller.state == .running)
        #expect(controller.lastRecovery?.reason == "wake from sleep")
    }

    @Test func failedInputStartIsRetriedWithBackoff() {
        system.failingInputStarts = 2
        controller.setDiscordApps(["com.hnc.Discord"])
        #expect(controller.state == .error)
        scheduler.advance(by: 0.5)
        #expect(controller.state == .error)                    // second failure
        scheduler.advance(by: 0.9)
        #expect(controller.state == .error)                    // next attempt after 1 s
        scheduler.advance(by: 0.2)
        #expect(controller.state == .running)
        #expect(system.outputs.count == 1)                     // the output leg was never restarted
    }

    @Test func retriesStopWhenDiscordQuits() {
        system.failingInputStarts = 100
        controller.setDiscordApps(["com.hnc.Discord"])
        controller.setDiscordApps([])
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 60)
        #expect(system.inputs.count == 1)
    }

    @Test func inputWatchdogRebuildsOnlyTheInput() throws {
        startCall()
        scheduler.advance(by: 5)
        #expect(controller.counters.inputRebuilds == 0)
        system.inputs[0].stalled = true
        scheduler.advance(by: 3)
        #expect(controller.counters.inputRebuilds == 1)
        #expect(system.liveInputs.count == 1 && system.liveInputs[0] !== system.inputs[0])
        expectOutputUntouched()
        #expect(try #require(controller.lastRecovery).reason.contains("IO stalled"))
    }

    @Test func outputWatchdogRebuildsBothLegs() {
        startCall()
        output.stalled = true
        scheduler.advance(by: 3)
        #expect(controller.counters.outputRebuilds == 1)
        #expect(system.liveOutputs.count == 1 && system.liveOutputs[0] !== output)
        #expect(system.liveInputs.count == 1)
    }

    @Test func overloadIsCountedNotRebuilt() {
        startCall()
        output.onEvent?(.overload(uid: blackHole.uid))
        system.inputs[0].onEvent?(.overload(uid: "scarlett"))
        scheduler.advance(by: 1)
        #expect(controller.counters.overloads == 2)
        #expect(controller.counters.inputRebuilds == 0)
    }

    @Test func underrunsAreCumulatedAcrossInputRebuilds() {
        startCall()
        output.fakeStats.underruns = 2
        scheduler.advance(by: 1)
        #expect(controller.counters.underruns == 2)
        #expect(controller.counters.underrunsSinceInputStart == 2)

        system.update("scarlett") { $0.sampleRate = 44100 }
        system.inputs[0].onEvent?(.sampleRateChanged(uid: "scarlett", rate: 44100))
        scheduler.advance(by: 0.6)
        #expect(controller.counters.underrunsSinceInputStart == 0)
        output.fakeStats.underruns = 3
        scheduler.advance(by: 1)
        #expect(controller.counters.underruns == 3)
        #expect(controller.counters.underrunsSinceInputStart == 1)
    }

    @Test func latencyWindowPublishedEveryFiveSeconds() throws {
        startCall()
        output.fakeStats.latencyMean = 0.05
        output.fakeStats.latencyMin = 0.049
        output.fakeStats.latencyMax = 0.051
        output.fakeStats.latencyCount = 400
        var published = 0
        controller.onChange = { _ in published += 1 }
        scheduler.advance(by: 4)
        #expect(controller.latency == nil)
        scheduler.advance(by: 1)
        let latency = try #require(controller.latency)
        #expect(abs(latency.meanMs - 50) < 1e-9)
        #expect(output.latencyResets == 1)
        #expect(published >= 1)
    }
}
