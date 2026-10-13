import Foundation

/// A change requested from the command line (`jumphertz --set-…`).
public enum ConfigEdit: Equatable, Sendable {
    case inputChannel(Int)
    case gainDb(Double)
    /// nil = "auto" (first Scarlett found).
    case inputDevice(String?)
    /// nil = "auto" (the device named "BlackHole 2ch").
    case outputDevice(String?)
    case reset
}

/// How the running agent applies a change.
public enum ConfigEffect: Equatable, Sendable {
    case none
    /// Applied on the next IO cycle, without interruption.
    case live
    /// The input leg is rebuilt (≈ 30 ms of silence); BlackHole is not touched.
    case rebuildsInput
    /// Both legs are rebuilt on the new output device; no device format is written while Discord runs.
    case rebuildsOutput
    case startsOrStops
}

public struct ConfigEditOutcome: Equatable, Sendable {
    public var config: Config
    /// "inputChannel: 1 → 2" lines.
    public var changes: [String]
    public var warnings: [String]
    public var effect: ConfigEffect
}

public enum ConfigEditError: Error, Equatable, CustomStringConvertible {
    case currentFileInvalid(ConfigError)
    case channelNotPositive(Int)
    case channelOutOfRange(requested: Int, device: String, inputs: Int)
    case invalidNumber(String)
    case gainOutOfRange(Double)
    case unknownInputDevice(uid: String, valid: [DeviceInfo])
    case notAScarlett(uid: String, name: String)
    case unknownOutputDevice(uid: String, valid: [DeviceInfo])
    case notABlackHole(uid: String, name: String)
    case channelNotOnNewDevice(channel: Int, device: String, inputs: Int)

    public var description: String {
        switch self {
        case let .currentFileInvalid(error):
            return "\(error)\nFix the file, or start over with: jumphertz --reset-config"
        case let .channelNotPositive(channel):
            return "Input channel \(channel) is not valid: channels start at 1."
        case let .channelOutOfRange(requested, device, inputs):
            return "Input channel \(requested) does not exist on \"\(device)\" (\(inputs) inputs: use 1–\(inputs))."
        case let .invalidNumber(raw):
            return "\"\(raw)\" is not a number (examples: -6, 0, +3.5)."
        case let .gainOutOfRange(gain):
            return "Gain \(Self.format(gain)) dB is out of range (\(Int(Config.gainRange.lowerBound)) to +\(Int(Config.gainRange.upperBound)) dB)."
        case let .unknownInputDevice(uid, valid):
            return "No Scarlett with UID \"\(uid)\" is connected.\n" + Self.list(valid, empty: "No Scarlett is connected.", command: "--set-device")
        case let .notAScarlett(uid, name):
            return "\"\(name)\" (\(uid)) is not a Focusrite Scarlett. Jumphertz only supports Scarlett interfaces."
        case let .unknownOutputDevice(uid, valid):
            return "No BlackHole device with UID \"\(uid)\".\n" + Self.list(valid, empty: "No BlackHole device is installed (brew install blackhole-2ch).", command: "--set-output")
        case let .notABlackHole(uid, name):
            return "\"\(name)\" (\(uid)) is not a BlackHole device. The bridge output must be BlackHole 2ch, 16ch or 64ch."
        case let .channelNotOnNewDevice(channel, device, inputs):
            return "The current input channel (\(channel)) does not exist on \"\(device)\" (\(inputs) inputs). Choose a channel first: jumphertz --set-channel 1"
        }
    }

    static func list(_ devices: [DeviceInfo], empty: String, command: String) -> String {
        guard !devices.isEmpty else { return empty }
        return "Valid values:\n" + devices.map { "  jumphertz \(command) \"\($0.uid)\"   (\($0.name))" }.joined(separator: "\n")
            + "\n  jumphertz \(command) auto"
    }

    static func format(_ gain: Double) -> String { String(format: "%+.1f", gain) }
}

/// Pure validation and application of command-line edits against the connected devices.
public enum ConfigEditing {
    /// Accepts "-6", "+3.5", "0", "-6dB".
    public static func parseGain(_ raw: String) throws -> Double {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasSuffix("db") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard let value = Double(text), value.isFinite else { throw ConfigEditError.invalidNumber(raw) }
        return value
    }

    /// "auto" (any case) or an empty string means automatic selection.
    public static func parseUID(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.lowercased() == "auto" ? nil : text
    }

    public static func apply(_ edit: ConfigEdit, to current: Config, devices: [DeviceInfo]) throws -> ConfigEditOutcome {
        var config = current
        var warnings: [String] = []
        let effect: ConfigEffect

        switch edit {
        case let .inputChannel(channel):
            guard channel >= 1 else { throw ConfigEditError.channelNotPositive(channel) }
            if case let .selected(device, _) = DeviceMatching.selectInput(from: devices, preferredUID: current.deviceUID) {
                guard channel <= device.inputChannels else {
                    throw ConfigEditError.channelOutOfRange(requested: channel, device: device.name, inputs: device.inputChannels)
                }
            } else {
                warnings.append("No Scarlett connected: channel \(channel) cannot be checked now; Jumphertz checks it when the interface is plugged in.")
            }
            config.inputChannel = channel
            effect = .live

        case let .gainDb(gain):
            guard Config.gainRange.contains(gain) else { throw ConfigEditError.gainOutOfRange(gain) }
            config.gainDb = gain
            effect = .live

        case let .inputDevice(uid):
            if let uid {
                let scarletts = devices.filter(DeviceMatching.isScarlett)
                guard let device = scarletts.first(where: { $0.uid == uid }) else {
                    if let other = devices.first(where: { $0.uid == uid }) {
                        throw ConfigEditError.notAScarlett(uid: uid, name: other.name)
                    }
                    throw ConfigEditError.unknownInputDevice(uid: uid, valid: scarletts.sorted { $0.uid < $1.uid })
                }
                guard current.inputChannel <= device.inputChannels else {
                    throw ConfigEditError.channelNotOnNewDevice(channel: current.inputChannel, device: device.name,
                                                               inputs: device.inputChannels)
                }
            }
            config.deviceUID = uid
            effect = .rebuildsInput

        case let .outputDevice(uid):
            if let uid {
                let blackHoles = devices.filter { DeviceMatching.isBlackHole($0) && $0.outputChannels > 0 }
                guard blackHoles.contains(where: { $0.uid == uid }) else {
                    if let other = devices.first(where: { $0.uid == uid }) {
                        throw ConfigEditError.notABlackHole(uid: uid, name: other.name)
                    }
                    throw ConfigEditError.unknownOutputDevice(uid: uid, valid: blackHoles.sorted { $0.name < $1.name })
                }
                warnings.append("Select this device as the input in Discord › Settings › Voice & Video.")
            } else if DeviceMatching.selectOutput(from: devices, preferredUID: nil) == .noneFound {
                warnings.append("\"\(DeviceMatching.defaultOutputName)\" is not installed (brew install blackhole-2ch).")
            }
            config.outputDeviceUID = uid
            effect = .rebuildsOutput

        case .reset:
            config = .default
            effect = Self.effect(from: current, to: config)
        }

        try config.validate()
        let changes = Self.changes(from: current, to: config)
        return ConfigEditOutcome(config: config, changes: changes, warnings: warnings,
                                 effect: changes.isEmpty ? .none : effect)
    }

    /// The strongest effect a whole-config change has on a running agent.
    public static func effect(from old: Config, to new: Config) -> ConfigEffect {
        if old.enabled != new.enabled { return .startsOrStops }
        if old.outputDeviceUID != new.outputDeviceUID || old.outputBufferFrames != new.outputBufferFrames
            || old.reducedLatencyMargin != new.reducedLatencyMargin { return .rebuildsOutput }
        if old.deviceUID != new.deviceUID || old.bufferFrames != new.bufferFrames { return .rebuildsInput }
        if old.inputChannel != new.inputChannel || old.gainDb != new.gainDb { return .live }
        return .none
    }

    public static func changes(from old: Config, to new: Config) -> [String] {
        func show(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "auto" }
        func show(_ value: Int?) -> String { value.map(String.init) ?? "default" }
        var lines: [String] = []
        if old.deviceUID != new.deviceUID { lines.append("deviceUID: \(show(old.deviceUID)) → \(show(new.deviceUID))") }
        if old.outputDeviceUID != new.outputDeviceUID {
            lines.append("outputDeviceUID: \(show(old.outputDeviceUID)) → \(show(new.outputDeviceUID))")
        }
        if old.inputChannel != new.inputChannel { lines.append("inputChannel: \(old.inputChannel) → \(new.inputChannel)") }
        if old.gainDb != new.gainDb {
            lines.append("gainDb: \(ConfigEditError.format(old.gainDb)) → \(ConfigEditError.format(new.gainDb))")
        }
        if old.enabled != new.enabled { lines.append("enabled: \(old.enabled) → \(new.enabled)") }
        if old.bufferFrames != new.bufferFrames { lines.append("bufferFrames: \(show(old.bufferFrames)) → \(show(new.bufferFrames))") }
        if old.outputBufferFrames != new.outputBufferFrames {
            lines.append("outputBufferFrames: \(show(old.outputBufferFrames)) → \(show(new.outputBufferFrames))")
        }
        if old.reducedLatencyMargin != new.reducedLatencyMargin {
            lines.append("reducedLatencyMargin: \(old.reducedLatencyMargin) → \(new.reducedLatencyMargin)")
        }
        return lines
    }
}

extension ConfigStore {
    /// Atomic: written to a temporary file in the same directory, then renamed over config.json, so readers
    /// (the agent) see either the old or the new file, never a partial one.
    public static func write(_ config: Config, to url: URL = Paths.configFile) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try config.encoded()
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// The config to edit from the command line: the file if valid, defaults if missing; an invalid file is
    /// an error (editing it would silently drop the user's other settings).
    public static func loadForEditing(from url: URL = Paths.configFile) throws -> Config {
        switch load(from: url) {
        case let .loaded(config): return config
        case .missing: return .default
        case let .invalid(error): throw ConfigEditError.currentFileInvalid(error)
        }
    }
}
