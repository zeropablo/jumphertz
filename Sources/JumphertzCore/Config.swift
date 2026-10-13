import Foundation

/// User configuration stored in `~/Library/Application Support/Jumphertz/config.json`.
/// Only device UIDs are stored, never AudioObjectIDs.
public struct Config: Equatable, Sendable {
    /// Scarlett UID. `nil` = first Scarlett found.
    public var deviceUID: String?
    /// Bridge output UID. `nil` = the device named "BlackHole 2ch".
    public var outputDeviceUID: String?
    /// 1-based input channel on the Scarlett.
    public var inputChannel: Int
    public var gainDb: Double
    public var enabled: Bool
    /// IO buffer size requested on the interface. `nil` = leave the HAL default untouched.
    /// The HAL runs a device at the smallest size any client asks for, so this also affects the Scarlett
    /// for every other app while the bridge runs.
    public var bufferFrames: Int?
    /// Latency lever 1: IO buffer size of Jumphertz's own IOProc on the output device (BlackHole).
    /// `nil` (default) = untouched.
    public var outputBufferFrames: Int?
    /// Latency lever 2: smaller jitter margin in the ring. `false` (default) = validated safe margin.
    public var reducedLatencyMargin: Bool

    public static let gainRange: ClosedRange<Double> = -60...24
    public static let bufferFramesRange: ClosedRange<Int> = 16...4096
    public static let `default` = Config(deviceUID: nil, outputDeviceUID: nil, inputChannel: 1, gainDb: 0,
                                         enabled: true)

    public init(deviceUID: String?, outputDeviceUID: String?, inputChannel: Int, gainDb: Double, enabled: Bool,
                bufferFrames: Int? = nil, outputBufferFrames: Int? = nil, reducedLatencyMargin: Bool = false) {
        self.deviceUID = deviceUID
        self.outputDeviceUID = outputDeviceUID
        self.inputChannel = inputChannel
        self.gainDb = gainDb
        self.enabled = enabled
        self.bufferFrames = bufferFrames
        self.outputBufferFrames = outputBufferFrames
        self.reducedLatencyMargin = reducedLatencyMargin
    }

    public var outputOptions: OutputOptions {
        OutputOptions(bufferFrames: outputBufferFrames, reducedMargin: reducedLatencyMargin)
    }

    public var linearGain: Float { Config.linearGain(dB: gainDb) }

    public static func linearGain(dB: Double) -> Float { Float(pow(10, dB / 20)) }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case invalidValue(key: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidJSON(detail): return "config.json is not valid JSON: \(detail)"
        case let .invalidValue(key, reason): return "config.json: \"\(key)\" \(reason)"
        }
    }
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case deviceUID, outputDeviceUID, inputChannel, gainDb, enabled, bufferFrames, outputBufferFrames, reducedLatencyMargin
    }

    /// Missing keys fall back to defaults; present keys must have the right type.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        inputChannel = try c.decodeIfPresent(Int.self, forKey: .inputChannel) ?? d.inputChannel
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? d.gainDb
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames)
        outputBufferFrames = try c.decodeIfPresent(Int.self, forKey: .outputBufferFrames)
        reducedLatencyMargin = try c.decodeIfPresent(Bool.self, forKey: .reducedLatencyMargin) ?? false
    }

    /// Writes `null` explicitly for unset UIDs so the file documents every key.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(outputDeviceUID, forKey: .outputDeviceUID)
        try c.encode(inputChannel, forKey: .inputChannel)
        try c.encode(gainDb, forKey: .gainDb)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(bufferFrames, forKey: .bufferFrames)
        try c.encode(outputBufferFrames, forKey: .outputBufferFrames)
        try c.encode(reducedLatencyMargin, forKey: .reducedLatencyMargin)
    }
}

extension Config {
    public static func parse(_ data: Data) throws -> Config {
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let key = context.codingPath.last?.stringValue ?? "?"
            throw ConfigError.invalidValue(key: key, reason: "has the wrong type")
        } catch {
            throw ConfigError.invalidJSON(String(describing: error))
        }
        try config.validate()
        return config
    }

    public func validate() throws {
        if inputChannel < 1 {
            throw ConfigError.invalidValue(key: "inputChannel", reason: "must be 1 or greater")
        }
        if !gainDb.isFinite || !Config.gainRange.contains(gainDb) {
            throw ConfigError.invalidValue(
                key: "gainDb",
                reason: "must be between \(Int(Config.gainRange.lowerBound)) and \(Int(Config.gainRange.upperBound))")
        }
        for (key, value) in [("bufferFrames", bufferFrames), ("outputBufferFrames", outputBufferFrames)] {
            if let value, !Config.bufferFramesRange.contains(value) {
                throw ConfigError.invalidValue(
                    key: key,
                    reason: "must be null or between \(Config.bufferFramesRange.lowerBound) and \(Config.bufferFramesRange.upperBound)")
            }
        }
        for (key, uid) in [("deviceUID", deviceUID), ("outputDeviceUID", outputDeviceUID)] {
            if let uid, uid.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ConfigError.invalidValue(key: key, reason: "must be null or a non-empty UID")
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Filesystem locations. Everything lives in the user's home; nothing requires elevated privileges.
public enum Paths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jumphertz", isDirectory: true)
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
}

public enum ConfigStore {
    public enum LoadResult {
        case loaded(Config)
        case missing
        case invalid(ConfigError)
    }

    public static func load(from url: URL = Paths.configFile) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do {
            return .loaded(try Config.parse(data))
        } catch let error as ConfigError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidJSON(String(describing: error)))
        }
    }

    /// The config to run with: the file if valid, otherwise defaults.
    public static func effective(from url: URL = Paths.configFile) -> (Config, LoadResult) {
        let result = load(from: url)
        if case let .loaded(config) = result { return (config, result) }
        return (.default, result)
    }
}
