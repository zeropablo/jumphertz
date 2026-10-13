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

/// Decides whether the bridge should run and keeps it in that state. Main thread only.
public final class BridgeController {
    public enum State: String, Codable, Sendable {
        /// Enabled, Discord not running: nothing allocated, no audio thread.
        case idle
        case disabled
        case waitingForPermission
        case permissionDenied
        case waitingForDevices
        case running
        case error
    }

    public private(set) var state: State = .idle
    public private(set) var message: String?
    public private(set) var warnings: [String] = []
    public private(set) var discordApps: Set<String> = []
    public private(set) var config: Config
    public var bridge: AudioBridge? { activeBridge }

    /// Called after every reconciliation.
    public var onChange: ((BridgeController) -> Void)?

    private let system: AudioSystem
    private let permission: MicPermissionProviding
    private var activeBridge: AudioBridge?
    private var permissionRequestInFlight = false

    public init(system: AudioSystem, permission: MicPermissionProviding, config: Config) {
        self.system = system
        self.permission = permission
        self.config = config
    }

    public var discordRunning: Bool { !discordApps.isEmpty }
    public var permissionStatus: MicPermission { permission.status }

    public func setDiscordApps(_ apps: Set<String>) {
        guard apps != discordApps else { return }
        discordApps = apps
        Log.controller.info("Discord running: \(apps.sorted().joined(separator: ", "), privacy: .public)")
        reconcile()
    }

    /// Tears the bridge down and builds it again (device or rate changes, wake from sleep).
    public func rebuild(reason: String) {
        stopBridge(reason: reason)
        reconcile()
    }

    public func shutdown() {
        stopBridge(reason: "shutdown")
        state = .idle
    }

    public func reconcile() {
        defer { onChange?(self) }

        guard config.enabled else {
            stopBridge(reason: "disabled in config")
            set(.disabled)
            return
        }
        guard discordRunning else {
            stopBridge(reason: "Discord not running")
            set(.idle)
            return
        }

        // Never touch the audio device before the permission is settled: while the system prompt is
        // pending, creating the IOProc blocks inside coreaudiod.
        switch permission.status {
        case .granted:
            break
        case .denied:
            stopBridge(reason: "microphone permission denied")
            set(.permissionDenied, "Microphone access denied. System Settings › Privacy & Security › Microphone › MicBridge.")
            return
        case .notDetermined:
            set(.waitingForPermission, "Waiting for microphone permission.")
            requestPermission()
            return
        }

        if activeBridge != nil {
            set(.running)
            return
        }
        startBridge()
    }

    private func startBridge() {
        let devices = system.devices()
        var warnings: [String] = []

        let input: DeviceInfo
        switch DeviceMatching.selectInput(from: devices, preferredUID: config.deviceUID) {
        case let .selected(device, warning):
            input = device
            if let warning { warnings.append(warning) }
        case let .configuredNotFound(uid):
            set(.waitingForDevices, "Configured Scarlett \(uid) is not connected.")
            return
        case .noneFound:
            set(.waitingForDevices, "No Focusrite Scarlett connected.")
            return
        }

        let output: DeviceInfo
        switch DeviceMatching.selectOutput(from: devices, preferredUID: config.outputDeviceUID) {
        case let .selected(device): output = device
        case let .configuredNotFound(uid):
            set(.waitingForDevices, "Configured output device \(uid) is not present.")
            return
        case .noneFound:
            set(.waitingForDevices, "\(DeviceMatching.defaultOutputName) not found (brew install blackhole-2ch).")
            return
        }

        for aggregate in DeviceMatching.aggregatesContaining(output.uid, in: system.visibleAggregates()) {
            let warning = DeviceMatching.feedbackWarning(outputName: output.name, aggregate: aggregate)
            Log.controller.warning("\(warning, privacy: .public)")
            warnings.append(warning)
        }
        if let frames = config.bufferFrames {
            warnings.append("bufferFrames = \(frames): \(input.name) uses this buffer size for every app while the bridge runs.")
        }
        self.warnings = warnings

        let bridge = system.makeBridge(input: input, output: output, inputChannel: config.inputChannel,
                                       gainDb: config.gainDb, bufferFrames: config.bufferFrames)
        do {
            try bridge.start()
            activeBridge = bridge
            set(.running)
        } catch {
            Log.controller.error("Bridge start failed: \(String(describing: error), privacy: .public)")
            set(.error, String(describing: error))
        }
    }

    private func stopBridge(reason: String) {
        guard let bridge = activeBridge else { return }
        Log.controller.info("Stopping bridge: \(reason, privacy: .public)")
        bridge.stop()
        activeBridge = nil
        warnings = []
    }

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
