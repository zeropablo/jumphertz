import Foundation
import os

public enum DiscordApps {
    public static let bundleIDs: Set<String> = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]

    /// Exact match only: Discord's helper processes use other bundle IDs (e.g. com.hnc.Discord.helper).
    public static func isDiscord(bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }
}

public enum MicPermission: String, Codable, Sendable {
    case granted, denied, notDetermined
}

/// Microphone authorization for this app (TCC). Abstracted for tests.
public protocol MicPermissionProviding: AnyObject {
    var status: MicPermission { get }
    /// Shows the system prompt if needed. The completion may run on any thread.
    func request(_ completion: @escaping (MicPermission) -> Void)
}

/// Runs the two legs of the bridge and keeps them matching the hardware. Main thread only.
///
/// - The output leg (Jumphertz's IOProc on BlackHole) lives as long as Discord runs. The output device's format
///   is never written while Discord runs: Discord loses its input when it changes during a call. Its rate is
///   set to 48 kHz only while Discord is not running.
/// - The input leg (IOProc on the Scarlett) is rebuilt on its own when the interface changes (rate, hot plug,
///   wake); meanwhile the output leg keeps running and writes silence.
public final class BridgeController {
    public enum State: String, Codable, Sendable {
        /// Enabled, Discord not running: nothing allocated, no audio thread, no timer.
        case idle
        case disabled
        /// The Mac is going to sleep or has just woken up.
        case suspended
        case waitingForPermission
        case permissionDenied
        /// Output device or interface missing (the output leg keeps running if only the interface is missing).
        case waitingForDevices
        case running
        /// Start failed; retried with backoff.
        case error
    }

    public struct Recovery: Codable, Equatable, Sendable {
        public var reason: String
        /// From the first hardware event to both legs running again.
        public var milliseconds: Int
        public var at: Date
    }

    /// Cumulated since the agent started (they survive leg rebuilds).
    public struct Counters: Codable, Equatable, Sendable {
        public var underruns: UInt64 = 0
        public var overflows: UInt64 = 0
        public var droppedSamples: UInt64 = 0
        public var overloads: UInt64 = 0
        public var inputRebuilds = 0
        public var outputRebuilds = 0
        /// Must stay 0: each one may have cost Discord its input.
        public var outputFormatChangesWhileDiscordRunning = 0
        /// Since the current input leg started (i.e. after its convergence).
        public var underrunsSinceInputStart: UInt64 = 0
        public var overflowsSinceInputStart: UInt64 = 0
    }

    /// Latency measured from the HAL timestamps over the last status window.
    public struct LatencyWindow: Codable, Equatable, Sendable {
        public var meanMs: Double
        public var minMs: Double
        public var maxMs: Double
        public var samples: UInt64
    }

    public static let standardOutputRate: Double = 48000
    /// Hardware notifications often come in bursts: wait for the burst to settle before checking.
    public static let debounceInterval: TimeInterval = 0.5
    /// Delays between attempts after a failed start; the last one repeats.
    public static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
    /// While the output leg runs: watchdog / statistics tick...
    public static let tickInterval: TimeInterval = 1
    /// ...IO is considered stalled after this many ticks without cycles...
    public static let watchdogStrikes = 2
    /// ...and the status is published every this many ticks.
    public static let statusEveryTicks = 5

    public private(set) var state: State = .idle
    public private(set) var message: String?
    public private(set) var warnings: [String] = []
    public private(set) var discordApps: Set<String> = []
    public private(set) var config: Config
    public private(set) var suspended = false
    public private(set) var counters = Counters()
    public private(set) var lastRecovery: Recovery?
    public private(set) var latency: LatencyWindow?
    public private(set) var output: OutputLeg?
    public private(set) var input: InputLeg?
    /// Problems with the configuration itself (invalid file, channel the interface does not have). Kept until
    /// a valid configuration resolves them.
    public private(set) var configWarnings: [String] = []

    /// Everything `jumphertz --status` should show.
    public var allWarnings: [String] { configWarnings + warnings }

    /// Called after every state evaluation and periodically while bridging.
    public var onChange: ((BridgeController) -> Void)?

    private let system: AudioSystem
    private let permission: MicPermissionProviding
    private let scheduler: Scheduler
    private var permissionRequestInFlight = false

    private var pendingCheck: Cancellable?
    private var pendingEvent: (reason: String, at: Date)?
    private var disruption: (reason: String, at: Date)?
    private var retryWork: Cancellable?
    private var retryAttempt = 0
    private var tickWork: Cancellable?
    private var ticks = 0
    private var lastOutputCycles: UInt64 = 0
    private var lastInputCycles: UInt64 = 0
    private var outputMisses = 0
    private var inputMisses = 0
    // Baselines of the legs' own counters (reset when a leg is recreated).
    private var seenUnderruns: UInt64 = 0
    private var seenOverflows: UInt64 = 0
    private var seenDropped: UInt64 = 0
    private var outputWarnings: [String] = []

    public init(system: AudioSystem, permission: MicPermissionProviding, config: Config,
                scheduler: Scheduler = MainQueueScheduler()) {
        self.system = system
        self.permission = permission
        self.config = config
        self.scheduler = scheduler
        system.onDevicesChanged = { [weak self] in self?.noteEvent("device list changed") }
    }

    public var discordRunning: Bool { !discordApps.isEmpty }
    public var permissionStatus: MicPermission { permission.status }

    // MARK: - Configuration (hot reload)

    /// Applies a new valid configuration with the least disruption: channel and gain live; interface or
    /// input buffer → input leg only; output options → both legs, without writing any device format.
    public func setConfig(_ new: Config) {
        let old = config
        guard new != old else {
            if !configWarnings.isEmpty {
                configWarnings = []
                onChange?(self)
            }
            return
        }
        config = new
        configWarnings = []
        for line in ConfigEditing.changes(from: old, to: new) {
            Log.controller.notice("Configuration changed: \(line, privacy: .public)")
        }

        switch ConfigEditing.effect(from: old, to: new) {
        case .none:
            onChange?(self)
        case .startsOrStops:
            reconcile()
        case .rebuildsOutput:
            if output != nil {
                restartOutput(reason: "configuration changed")
            } else {
                reconcile()
            }
        case .rebuildsInput:
            if input != nil {
                restartInput(reason: "configuration changed")
            } else {
                reconcile()
            }
        case .live:
            if let input {
                if new.inputChannel != old.inputChannel { applyChannelLive(new.inputChannel, on: input, previous: old.inputChannel) }
                if new.gainDb != old.gainDb { input.setGain(dB: new.gainDb) }
            }
            onChange?(self)
        }
    }

    /// config.json could not be read: keep running with the previous settings and say so.
    public func rejectConfig(_ error: ConfigError) {
        let warning = "\(error) — keeping the previous settings."
        Log.controller.error("Invalid configuration: \(String(describing: error), privacy: .public); keeping the previous settings")
        configWarnings = [warning]
        onChange?(self)
    }

    private func applyChannelLive(_ channel: Int, on input: InputLeg, previous: Int) {
        do {
            try input.setInputChannel(channel)
            Log.controller.notice("Input channel \(channel) applied live")
        } catch {
            config.inputChannel = previous
            let warning = "inputChannel \(channel) does not exist on \(input.device.name) (\(input.device.inputChannels) inputs); keeping channel \(previous)."
            Log.controller.error("\(warning, privacy: .public)")
            configWarnings = [warning]
        }
    }

    public func setDiscordApps(_ apps: Set<String>) {
        guard apps != discordApps else { return }
        let before = discordApps
        discordApps = apps
        for app in apps.subtracting(before).sorted() { Log.controller.notice("Discord detected: \(app, privacy: .public)") }
        for app in before.subtracting(apps).sorted() { Log.controller.notice("Discord quit: \(app, privacy: .public)") }
        reconcile()
    }

    /// Sleep: release the hardware before the system powers it down. Wake: rebuild from scratch.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        if suspended {
            Log.controller.notice("System going to sleep: stopping the bridge")
            stopLegs(reason: "system sleep")
        } else {
            Log.controller.notice("System woke up: rebuilding the bridge")
            disruption = ("wake from sleep", scheduler.now)
        }
        reconcile()
    }

    /// Tears both legs down and builds them again.
    public func rebuild(reason: String) {
        disruption = (reason, scheduler.now)
        restartOutput(reason: reason)
    }

    public func shutdown() {
        cancelTimers()
        stopLegs(reason: "shutdown")
        state = .idle
    }

    // MARK: - Reconciliation

    public func reconcile() {
        defer { onChange?(self) }

        guard config.enabled else { return park(.disabled, reason: "disabled in config") }
        guard discordRunning else {
            park(.idle, reason: "Discord not running")
            ensureStandardOutputRate()
            return
        }
        guard !suspended else { return park(.suspended, reason: "system sleep") }

        // Never touch an audio device before the permission is settled: while the system prompt is
        // pending, creating an IOProc blocks inside coreaudiod.
        switch permission.status {
        case .granted:
            break
        case .denied:
            park(.permissionDenied, reason: "microphone permission denied")
            message = "Microphone access denied. System Settings › Privacy & Security › Microphone › Jumphertz."
            return
        case .notDetermined:
            park(.waitingForPermission, reason: "waiting for microphone permission")
            message = "Waiting for microphone permission."
            requestPermission()
            return
        }

        // The output leg first: it carries Discord's stream, with or without an interface.
        if output == nil, !startOutput() { return }
        if input == nil {
            startInput()
        } else {
            set(.running)
        }
    }

    /// Not supposed to bridge: release everything, including timers.
    private func park(_ state: State, reason: String) {
        cancelTimers()
        disruption = nil
        stopLegs(reason: reason)
        set(state)
    }

    private var shouldBridge: Bool {
        config.enabled && discordRunning && !suspended && permission.status == .granted
    }

    /// With Discord not running, put the output device back to the standard rate so that the next call
    /// starts at 48 kHz. Never while Discord runs.
    private func ensureStandardOutputRate() {
        guard !discordRunning,
              case let .selected(device) = DeviceMatching.selectOutput(from: system.devices().filter(\.isAlive),
                                                                       preferredUID: config.outputDeviceUID),
              device.sampleRate != Self.standardOutputRate else { return }
        do {
            try system.setNominalSampleRate(Self.standardOutputRate, of: device)
            Log.controller.notice("Set \(device.name, privacy: .public) to \(Int(Self.standardOutputRate)) Hz (was \(Int(device.sampleRate)) Hz; Discord not running)")
        } catch {
            Log.controller.error("Cannot set \(device.name, privacy: .public) to \(Int(Self.standardOutputRate)) Hz: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Legs

    /// Returns false when the output leg could not run (state set accordingly).
    private func startOutput() -> Bool {
        retryWork?.cancel()
        retryWork = nil
        let devices = system.devices().filter(\.isAlive)
        let device: DeviceInfo
        switch DeviceMatching.selectOutput(from: devices, preferredUID: config.outputDeviceUID) {
        case let .selected(found): device = found
        case let .configuredNotFound(uid):
            waitForDevices("Configured output device \(uid) is not present.")
            return false
        case .noneFound:
            waitForDevices("\(DeviceMatching.defaultOutputName) not found (brew install blackhole-2ch).")
            return false
        }

        var warnings: [String] = []
        for aggregate in DeviceMatching.aggregatesContaining(device.uid, in: system.visibleAggregates()) {
            let warning = DeviceMatching.feedbackWarning(outputName: device.name, aggregate: aggregate)
            Log.controller.warning("\(warning, privacy: .public)")
            warnings.append(warning)
        }
        if device.sampleRate != Self.standardOutputRate {
            let warning = "\(device.name) runs at \(Int(device.sampleRate)) Hz (Discord was already running): left as is, resampling to it."
            Log.controller.notice("\(warning, privacy: .public)")
            warnings.append(warning)
        }
        if let frames = config.outputBufferFrames {
            warnings.append("Latency lever: outputBufferFrames = \(frames) on \(device.name).")
        }
        if config.reducedLatencyMargin { warnings.append("Latency lever: reducedLatencyMargin on.") }

        let leg = system.makeOutputLeg(device: device, options: config.outputOptions)
        leg.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try leg.start()
        } catch {
            Log.controller.error("Output leg start failed: \(String(describing: error), privacy: .public)")
            set(.error, String(describing: error))
            scheduleRetry()
            return false
        }
        output = leg
        outputWarnings = warnings
        seenUnderruns = 0
        seenOverflows = 0
        lastOutputCycles = 0
        outputMisses = 0
        startTicking()
        return true
    }

    private func startInput() {
        guard let output else { return }
        retryWork?.cancel()
        retryWork = nil
        let devices = system.devices().filter(\.isAlive)
        var warnings = outputWarnings

        let device: DeviceInfo
        switch DeviceMatching.selectInput(from: devices, preferredUID: config.deviceUID) {
        case let .selected(found, warning):
            device = found
            if let warning { warnings.append(warning) }
        case let .configuredNotFound(uid):
            return waitForDevices("Configured Scarlett \(uid) is not connected (\(output.device.name) stream kept alive).")
        case .noneFound:
            return waitForDevices("No Focusrite Scarlett connected (\(output.device.name) stream kept alive).")
        }
        if let frames = config.bufferFrames {
            warnings.append("bufferFrames = \(frames): \(device.name) uses this buffer size for every app while the bridge runs.")
        }

        // A configured channel the interface does not have (e.g. after switching to a smaller Scarlett) is a
        // configuration problem, not a hardware one: use channel 1, say so, do not retry.
        var channel = config.inputChannel
        if channel > device.inputChannels {
            let warning = "inputChannel \(channel) does not exist on \(device.name) (\(device.inputChannels) inputs); using channel 1. Fix it with: jumphertz --set-channel N"
            Log.controller.error("\(warning, privacy: .public)")
            configWarnings = [warning]
            channel = 1
        }

        let leg = system.makeInputLeg(device: device, inputChannel: channel, gainDb: config.gainDb,
                                      bufferFrames: config.bufferFrames, output: output)
        leg.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try leg.start()
        } catch {
            Log.controller.error("Input leg start failed: \(String(describing: error), privacy: .public)")
            set(.error, String(describing: error))
            scheduleRetry()
            return
        }
        input = leg
        retryAttempt = 0
        seenDropped = 0
        lastInputCycles = 0
        inputMisses = 0
        counters.underrunsSinceInputStart = 0
        counters.overflowsSinceInputStart = 0
        set(.running)
        self.warnings = warnings
        Log.controller.notice("Bridge running: \(device.name, privacy: .public) ch \(self.config.inputChannel) @ \(Int(leg.sampleRate)) Hz → \(output.device.name, privacy: .public) @ \(Int(output.sampleRate)) Hz")

        if let disruption {
            let ms = Int((scheduler.now.timeIntervalSince(disruption.at) * 1000).rounded())
            lastRecovery = Recovery(reason: disruption.reason, milliseconds: ms, at: scheduler.now)
            Log.controller.notice("Recovered from \(disruption.reason, privacy: .public) in \(ms) ms")
            self.disruption = nil
        }
    }

    private func waitForDevices(_ message: String) {
        // Device list notifications trigger the next attempt; no polling.
        if state != .waitingForDevices || self.message != message {
            Log.controller.notice("Waiting for devices: \(message, privacy: .public)")
        }
        set(.waitingForDevices, message)
        warnings = outputWarnings
    }

    private func stopInput(reason: String) {
        guard let leg = input else { return }
        accumulateStats()
        Log.controller.notice("Stopping input leg: \(reason, privacy: .public)")
        leg.onEvent = nil
        leg.stop()
        input = nil
    }

    private func stopLegs(reason: String) {
        stopInput(reason: reason)
        stopTicking()
        guard let leg = output else { return }
        accumulateStats()
        Log.controller.notice("Stopping output leg: \(reason, privacy: .public)")
        leg.onEvent = nil
        leg.stop()
        output = nil
        outputWarnings = []
        warnings = []
        latency = nil
    }

    private func restartInput(reason: String) {
        counters.inputRebuilds += 1
        Log.controller.notice("Rebuilding input leg: \(reason, privacy: .public)")
        stopInput(reason: reason)
        reconcile()
    }

    private func restartOutput(reason: String) {
        counters.outputRebuilds += 1
        Log.controller.notice("Rebuilding output leg: \(reason, privacy: .public)")
        stopLegs(reason: reason)
        reconcile()
    }

    // MARK: - Hardware events

    private func handle(_ event: BridgeEvent) {
        switch event {
        case let .overload(uid):
            counters.overloads += 1
            Log.controller.notice("IO overload on \(self.name(of: uid), privacy: .public) (#\(self.counters.overloads))")
        case let .sampleRateChanged(uid, rate):
            noteEvent("\(name(of: uid)) sample rate changed to \(Int(rate)) Hz")
        case let .formatChanged(uid):
            noteEvent("\(name(of: uid)) channel layout changed")
        case let .deviceDied(uid):
            noteEvent("\(name(of: uid)) disconnected")
        }
    }

    private func name(of uid: String) -> String {
        if output?.device.uid == uid { return output!.device.name }
        if input?.device.uid == uid { return input!.device.name }
        return uid
    }

    /// Debounces bursts of notifications into one health check.
    private func noteEvent(_ reason: String) {
        guard shouldBridge else { return }
        if pendingEvent == nil { pendingEvent = (reason, scheduler.now) }
        pendingCheck?.cancel()
        pendingCheck = scheduler.schedule(after: Self.debounceInterval) { [weak self] in self?.healthCheck() }
    }

    enum DeviceProblem: Equatable {
        case gone
        case reconnected
        case rateChanged(from: Double, to: Double)
        case layoutChanged

        func describe(_ name: String) -> String {
            switch self {
            case .gone: return "\(name) disconnected"
            case .reconnected: return "\(name) reconnected"
            case let .rateChanged(from, to): return "\(name) sample rate \(Int(from)) → \(Int(to)) Hz"
            case .layoutChanged: return "\(name) channel layout changed"
            }
        }

        /// The device is still there but no longer presents the same format.
        var isFormatChange: Bool {
            switch self {
            case .rateChanged, .layoutChanged: return true
            case .gone, .reconnected: return false
            }
        }
    }

    /// Why a leg no longer matches its device, if it does not.
    static func problem(device: DeviceInfo, rate: Double, output: Bool, devices: [DeviceInfo]) -> DeviceProblem? {
        guard let current = devices.first(where: { $0.uid == device.uid }), current.isAlive else { return .gone }
        // Same UID, new object: unplugged and plugged back within the debounce window.
        if current.id != device.id { return .reconnected }
        if current.sampleRate != rate { return .rateChanged(from: rate, to: current.sampleRate) }
        let channels = output ? (current.outputChannels, device.outputChannels) : (current.inputChannels, device.inputChannels)
        if channels.0 != channels.1 { return .layoutChanged }
        return nil
    }

    private func healthCheck() {
        pendingCheck = nil
        guard let event = pendingEvent else { return }
        pendingEvent = nil
        guard shouldBridge else { return reconcile() }
        let devices = system.devices()

        guard let output else {
            // Waiting for the output device or in error: try now rather than at the next retry.
            disruption = disruption ?? event
            return reconcile()
        }
        if let problem = Self.problem(device: output.device, rate: output.sampleRate, output: true, devices: devices) {
            let reason = problem.describe(output.device.name)
            if problem.isFormatChange, discordRunning {
                counters.outputFormatChangesWhileDiscordRunning += 1
                Log.controller.error("\(output.device.name, privacy: .public) format changed while Discord is running (\(reason, privacy: .public)); Jumphertz did not change it. Discord may have lost its input: leave and rejoin the voice channel.")
            }
            disruption = (reason, event.at)
            return restartOutput(reason: reason)
        }

        guard let input else {
            if state == .waitingForDevices || state == .error {
                // While the interface was missing, the clock restarts when it comes back: the time it stayed
                // unplugged is not part of the recovery time.
                disruption = state == .waitingForDevices
                    ? (disruption?.reason ?? event.reason, event.at)
                    : disruption ?? event
                startInput()
                onChange?(self)
            }
            return
        }
        if let problem = Self.problem(device: input.device, rate: input.sampleRate, output: false, devices: devices) {
            let reason = problem.describe(input.device.name)
            disruption = (reason, event.at)
            restartInput(reason: reason)
        }
    }

    // MARK: - Retry, watchdog, statistics

    private func scheduleRetry() {
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        retryAttempt += 1
        Log.controller.notice("Retrying in \(delay, format: .fixed(precision: 1)) s (attempt \(self.retryAttempt))")
        retryWork?.cancel()
        retryWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.reconcile()
        }
    }

    private func startTicking() {
        stopTicking()
        ticks = 0
        tickWork = scheduler.schedule(after: Self.tickInterval) { [weak self] in self?.tick() }
    }

    private func stopTicking() {
        tickWork?.cancel()
        tickWork = nil
    }

    /// Once per second while the output leg runs: IO watchdog for both legs, counters, periodic status.
    private func tick() {
        tickWork = nil
        guard let output else { return }
        ticks += 1

        let outputCycles = output.stats.cycles
        outputMisses = outputCycles == lastOutputCycles ? outputMisses + 1 : 0
        lastOutputCycles = outputCycles
        if outputMisses >= Self.watchdogStrikes {
            let stalled = Double(outputMisses) * Self.tickInterval
            disruption = ("\(output.device.name) IO stalled", scheduler.now.addingTimeInterval(-stalled))
            return restartOutput(reason: "\(output.device.name) IO stalled for \(Int(stalled)) s")
        }
        if let input {
            let inputCycles = input.cycleCount
            inputMisses = inputCycles == lastInputCycles ? inputMisses + 1 : 0
            lastInputCycles = inputCycles
            if inputMisses >= Self.watchdogStrikes {
                let stalled = Double(inputMisses) * Self.tickInterval
                disruption = ("\(input.device.name) IO stalled", scheduler.now.addingTimeInterval(-stalled))
                return restartInput(reason: "\(input.device.name) IO stalled for \(Int(stalled)) s")
            }
        }

        let changed = accumulateStats()
        if ticks % Self.statusEveryTicks == 0 {
            let stats = output.stats
            latency = stats.latencyCount > 0
                ? LatencyWindow(meanMs: stats.latencyMean * 1000, minMs: stats.latencyMin * 1000,
                                maxMs: stats.latencyMax * 1000, samples: stats.latencyCount)
                : nil
            output.resetLatencyWindow()
        }
        if changed || ticks % Self.statusEveryTicks == 0 { onChange?(self) }
        tickWork = scheduler.schedule(after: Self.tickInterval) { [weak self] in self?.tick() }
    }

    /// Folds the legs' counters into the cumulated ones and logs what happened. Returns true if anything did.
    @discardableResult
    private func accumulateStats() -> Bool {
        var changed = false
        if let output {
            let stats = output.stats
            if stats.underruns > seenUnderruns {
                let delta = stats.underruns - seenUnderruns
                counters.underruns += delta
                counters.underrunsSinceInputStart += delta
                Log.controller.notice("Underrun ×\(delta): the ring ran dry (total \(self.counters.underruns))")
                changed = true
            }
            if stats.overflows > seenOverflows {
                let delta = stats.overflows - seenOverflows
                counters.overflows += delta
                counters.overflowsSinceInputStart += delta
                Log.controller.notice("Overflow ×\(delta): output stalled, backlog dropped (total \(self.counters.overflows))")
                changed = true
            }
            if stats.resamplerErrors > 0 {
                Log.controller.error("Resampler errors: \(stats.resamplerErrors)")
            }
            seenUnderruns = stats.underruns
            seenOverflows = stats.overflows
        }
        if let input {
            let dropped = input.droppedSamples
            if dropped > seenDropped {
                counters.droppedSamples += dropped - seenDropped
                changed = true
            }
            seenDropped = dropped
        }
        return changed
    }

    private func cancelTimers() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingEvent = nil
        retryWork?.cancel()
        retryWork = nil
        retryAttempt = 0
        stopTicking()
    }

    // MARK: - Permission

    private func requestPermission() {
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        Log.controller.notice("Requesting microphone permission")
        permission.request { [weak self] result in
            let finish = {
                guard let self else { return }
                self.permissionRequestInFlight = false
                Log.controller.notice("Microphone permission: \(result.rawValue, privacy: .public)")
                self.reconcile()
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
    }

    private func set(_ state: State, _ message: String? = nil) {
        if state != self.state {
            if let message { Log.controller.notice("State \(state.rawValue, privacy: .public): \(message, privacy: .public)") }
            else { Log.controller.notice("State \(state.rawValue, privacy: .public)") }
        }
        self.state = state
        self.message = message
        if state != .running && state != .waitingForDevices { warnings = [] }
    }
}
