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

/// Decides whether the bridge should run and keeps it in that state, recovering from device, sample rate
/// and power changes. Main thread only.
public final class BridgeController {
    public enum State: String, Codable, Sendable {
        /// Enabled, Discord not running: nothing allocated, no audio thread, no timer.
        case idle
        case disabled
        /// The Mac is going to sleep or has just woken up.
        case suspended
        case waitingForPermission
        case permissionDenied
        case waitingForDevices
        case running
        /// Start failed; retried with backoff.
        case error
    }

    public struct Recovery: Codable, Equatable, Sendable {
        public var reason: String
        /// From the first hardware event to the bridge running again.
        public var milliseconds: Int
        public var at: Date
    }

    /// Hardware notifications often come in bursts (a rate switch changes several properties, a hot plug
    /// several devices): wait for the burst to settle before checking.
    public static let debounceInterval: TimeInterval = 0.5
    /// Delays between attempts after a failed start; the last one repeats.
    public static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
    /// The IO watchdog checks the cycle counter at this interval while the bridge runs...
    public static let watchdogInterval: TimeInterval = 1
    /// ...and rebuilds after this many consecutive checks without progress.
    public static let watchdogStrikes = 2

    public private(set) var state: State = .idle
    public private(set) var message: String?
    public private(set) var warnings: [String] = []
    public private(set) var discordApps: Set<String> = []
    public private(set) var config: Config
    public private(set) var suspended = false
    public private(set) var rebuildCount = 0
    public private(set) var overloadCount = 0
    public private(set) var lastRecovery: Recovery?
    public var bridge: AudioBridge? { activeBridge }

    /// Called after every state evaluation.
    public var onChange: ((BridgeController) -> Void)?

    private let system: AudioSystem
    private let permission: MicPermissionProviding
    private let scheduler: Scheduler
    private var activeBridge: AudioBridge?
    private var permissionRequestInFlight = false

    // Debounced health check: reason and time of the first event of the burst.
    private var pendingCheck: Cancellable?
    private var pendingEvent: (reason: String, at: Date)?
    // Start attempt triggered by a hardware event; used to measure the recovery time.
    private var disruption: (reason: String, at: Date)?
    private var retryWork: Cancellable?
    private var retryAttempt = 0
    private var watchdogWork: Cancellable?
    private var watchdogLastCycles: UInt64 = 0
    private var watchdogMisses = 0

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

    public func setDiscordApps(_ apps: Set<String>) {
        guard apps != discordApps else { return }
        discordApps = apps
        Log.controller.info("Discord running: \(apps.sorted().joined(separator: ", "), privacy: .public)")
        reconcile()
    }

    /// Sleep: release the hardware before the system powers it down. Wake: rebuild from scratch, as device
    /// IDs and clocks may have changed.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        if suspended {
            Log.controller.info("System going to sleep")
            stopBridge(reason: "system sleep")
        } else {
            Log.controller.info("System woke up")
            disruption = ("wake from sleep", scheduler.now)
        }
        reconcile()
    }

    /// Tears the bridge down and builds it again.
    public func rebuild(reason: String) {
        disruption = (reason, scheduler.now)
        restart(reason: reason)
    }

    public func shutdown() {
        cancelTimers()
        stopBridge(reason: "shutdown")
        state = .idle
    }

    // MARK: - Reconciliation

    public func reconcile() {
        defer { onChange?(self) }

        guard config.enabled else {
            return park(.disabled, reason: "disabled in config")
        }
        guard discordRunning else {
            return park(.idle, reason: "Discord not running")
        }
        guard !suspended else {
            return park(.suspended, reason: "system sleep")
        }

        // Never touch the audio device before the permission is settled: while the system prompt is
        // pending, creating the IOProc blocks inside coreaudiod.
        switch permission.status {
        case .granted:
            break
        case .denied:
            park(.permissionDenied, reason: "microphone permission denied")
            message = "Microphone access denied. System Settings › Privacy & Security › Microphone › MicBridge."
            return
        case .notDetermined:
            park(.waitingForPermission, reason: "waiting for microphone permission")
            message = "Waiting for microphone permission."
            requestPermission()
            return
        }

        if activeBridge != nil {
            set(.running)
            return
        }
        startBridge()
    }

    /// Not supposed to bridge: release everything, including timers.
    private func park(_ state: State, reason: String) {
        cancelTimers()
        disruption = nil
        stopBridge(reason: reason)
        set(state)
    }

    private func startBridge() {
        retryWork?.cancel()
        retryWork = nil
        let devices = system.devices()
        var warnings: [String] = []

        let input: DeviceInfo
        switch DeviceMatching.selectInput(from: devices.filter(\.isAlive), preferredUID: config.deviceUID) {
        case let .selected(device, warning):
            input = device
            if let warning { warnings.append(warning) }
        case let .configuredNotFound(uid):
            return waitForDevices("Configured Scarlett \(uid) is not connected.")
        case .noneFound:
            return waitForDevices("No Focusrite Scarlett connected.")
        }

        let output: DeviceInfo
        switch DeviceMatching.selectOutput(from: devices.filter(\.isAlive), preferredUID: config.outputDeviceUID) {
        case let .selected(device): output = device
        case let .configuredNotFound(uid):
            return waitForDevices("Configured output device \(uid) is not present.")
        case .noneFound:
            return waitForDevices("\(DeviceMatching.defaultOutputName) not found (brew install blackhole-2ch).")
        }

        for aggregate in DeviceMatching.aggregatesContaining(output.uid, in: system.visibleAggregates()) {
            let warning = DeviceMatching.feedbackWarning(outputName: output.name, aggregate: aggregate)
            Log.controller.warning("\(warning, privacy: .public)")
            warnings.append(warning)
        }
        if let frames = config.bufferFrames {
            warnings.append("bufferFrames = \(frames): \(input.name) uses this buffer size for every app while the bridge runs.")
        }

        let bridge = system.makeBridge(input: input, output: output, inputChannel: config.inputChannel,
                                       gainDb: config.gainDb, bufferFrames: config.bufferFrames)
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try bridge.start()
        } catch {
            Log.controller.error("Bridge start failed: \(String(describing: error), privacy: .public)")
            set(.error, String(describing: error))
            scheduleRetry()
            return
        }

        activeBridge = bridge
        retryAttempt = 0
        set(.running)
        self.warnings = warnings
        startWatchdog()

        if let disruption {
            let ms = Int((scheduler.now.timeIntervalSince(disruption.at) * 1000).rounded())
            lastRecovery = Recovery(reason: disruption.reason, milliseconds: ms, at: scheduler.now)
            Log.controller.info("Recovered from \(disruption.reason, privacy: .public) in \(ms) ms")
            self.disruption = nil
        }
    }

    private func waitForDevices(_ message: String) {
        // Device list notifications will trigger the next attempt; no timer needed.
        set(.waitingForDevices, message)
    }

    private func stopBridge(reason: String) {
        stopWatchdog()
        guard let bridge = activeBridge else { return }
        Log.controller.info("Stopping bridge: \(reason, privacy: .public)")
        bridge.onEvent = nil
        bridge.stop()
        activeBridge = nil
        warnings = []
    }

    private func restart(reason: String) {
        rebuildCount += 1
        Log.controller.info("Rebuilding bridge: \(reason, privacy: .public)")
        stopBridge(reason: reason)
        reconcile()
    }

    private var shouldBridge: Bool {
        config.enabled && discordRunning && !suspended && permission.status == .granted
    }

    // MARK: - Hardware events

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .overload:
            overloadCount += 1
            Log.controller.warning("IO overload #\(self.overloadCount)")
            onChange?(self)
        case let .sampleRateChanged(device, rate):
            noteEvent("\(device) sample rate changed to \(Int(rate)) Hz")
        case let .deviceDied(device):
            noteEvent("\(device) disconnected")
        }
    }

    /// Debounces bursts of notifications into one health check.
    private func noteEvent(_ reason: String) {
        // Nothing to protect while parked; the next reconcile reads the current devices anyway.
        guard shouldBridge else { return }
        if pendingEvent == nil { pendingEvent = (reason, scheduler.now) }
        pendingCheck?.cancel()
        pendingCheck = scheduler.schedule(after: Self.debounceInterval) { [weak self] in self?.healthCheck() }
    }

    private func healthCheck() {
        pendingCheck = nil
        guard let event = pendingEvent else { return }
        pendingEvent = nil
        guard shouldBridge else { return reconcile() }

        guard let bridge = activeBridge else {
            // Waiting for devices or in error: try now rather than waiting for the retry timer.
            if state == .waitingForDevices || state == .error {
                // While devices were missing, the clock restarts when they come back: the time the user
                // left the interface unplugged is not part of the recovery time.
                disruption = state == .waitingForDevices
                    ? (disruption?.reason ?? event.reason, event.at)
                    : disruption ?? event
                startBridge()
                onChange?(self)
            }
            return
        }
        if let problem = Self.problem(with: bridge, devices: system.devices()) {
            disruption = (problem, event.at)
            restart(reason: problem)
        }
    }

    /// Why the running bridge no longer matches the hardware, if it does not.
    static func problem(with bridge: AudioBridge, devices: [DeviceInfo]) -> String? {
        for (role, expected) in [("input", bridge.input), ("output", bridge.output)] {
            guard let current = devices.first(where: { $0.uid == expected.uid }), current.isAlive else {
                return "\(expected.name) (\(role)) disconnected"
            }
            // Same UID, new object: unplugged and plugged back within the debounce window.
            if current.id != expected.id { return "\(expected.name) (\(role)) reconnected" }
            if current.sampleRate != bridge.sampleRate {
                return "\(expected.name) sample rate \(Int(bridge.sampleRate)) → \(Int(current.sampleRate)) Hz"
            }
        }
        return nil
    }

    // MARK: - Retry and watchdog

    private func scheduleRetry() {
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        retryAttempt += 1
        Log.controller.info("Retrying in \(delay, format: .fixed(precision: 1)) s (attempt \(self.retryAttempt))")
        retryWork?.cancel()
        retryWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.reconcile()
        }
    }

    /// Catches an IOProc that stops being called without any notification (e.g. a clock lost after wake).
    private func startWatchdog() {
        stopWatchdog()
        watchdogLastCycles = activeBridge?.cycleCount ?? 0
        watchdogMisses = 0
        scheduleWatchdog()
    }

    private func scheduleWatchdog() {
        watchdogWork = scheduler.schedule(after: Self.watchdogInterval) { [weak self] in self?.watchdogTick() }
    }

    private func watchdogTick() {
        guard let bridge = activeBridge else { return }
        let cycles = bridge.cycleCount
        if cycles == watchdogLastCycles {
            watchdogMisses += 1
            if watchdogMisses >= Self.watchdogStrikes {
                let stalled = Double(watchdogMisses) * Self.watchdogInterval
                disruption = ("IO stalled", scheduler.now.addingTimeInterval(-stalled))
                restart(reason: "IO stalled for \(Int(stalled)) s")
                return
            }
        } else {
            watchdogMisses = 0
        }
        watchdogLastCycles = cycles
        scheduleWatchdog()
    }

    private func stopWatchdog() {
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    private func cancelTimers() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingEvent = nil
        retryWork?.cancel()
        retryWork = nil
        retryAttempt = 0
        stopWatchdog()
    }

    // MARK: - Permission

    private func requestPermission() {
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        Log.controller.info("Requesting microphone permission")
        permission.request { [weak self] result in
            let finish = {
                guard let self else { return }
                self.permissionRequestInFlight = false
                Log.controller.info("Microphone permission: \(result.rawValue, privacy: .public)")
                self.reconcile()
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
    }

    private func set(_ state: State, _ message: String? = nil) {
        if state != self.state || message != self.message {
            if let message { Log.controller.info("State \(state.rawValue, privacy: .public): \(message, privacy: .public)") }
            else { Log.controller.info("State \(state.rawValue, privacy: .public)") }
        }
        self.state = state
        self.message = message
        if state != .running { warnings = [] }
    }
}
