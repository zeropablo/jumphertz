import Foundation

/// Snapshot written by the agent for `jumphertz --status`.
public struct AgentStatus: Codable, Equatable, Sendable {
    public struct Leg: Codable, Equatable, Sendable {
        public var name: String
        public var uid: String
        public var sampleRate: Double
        public var bufferFrames: Int?
    }

    public struct InputInfo: Codable, Equatable, Sendable {
        public var leg: Leg
        public var channel: Int
        public var gainDb: Double
    }

    public var pid: Int32
    public var version: String
    public var state: BridgeController.State
    public var message: String?
    public var permission: MicPermission
    public var discordApps: [String]
    public var output: Leg?
    public var input: InputInfo?
    public var resampler: OutputStats?
    public var latency: BridgeController.LatencyWindow?
    public var counters: BridgeController.Counters
    public var lastRecovery: BridgeController.Recovery?
    public var warnings: [String]
    public var updatedAt: Date

    public init(controller: BridgeController, pid: Int32, version: String, now: Date = Date()) {
        self.pid = pid
        self.version = version
        state = controller.state
        message = controller.message
        permission = controller.permissionStatus
        discordApps = controller.discordApps.sorted()
        output = controller.output.map {
            Leg(name: $0.device.name, uid: $0.device.uid, sampleRate: $0.sampleRate, bufferFrames: $0.bufferFrameSize)
        }
        input = controller.input.map {
            InputInfo(leg: Leg(name: $0.device.name, uid: $0.device.uid, sampleRate: $0.sampleRate,
                               bufferFrames: $0.bufferFrameSize),
                      channel: $0.inputChannel, gainDb: controller.config.gainDb)
        }
        resampler = controller.output?.stats
        latency = controller.latency
        counters = controller.counters
        lastRecovery = controller.lastRecovery
        warnings = controller.allWarnings
        updatedAt = now
    }

    public var bridging: Bool { input != nil && output != nil }
}

public enum StatusStore {
    public static var fileURL: URL { Paths.supportDirectory.appendingPathComponent("status.json") }

    public static func write(_ status: AgentStatus, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(status).write(to: url, options: .atomic)
    }

    public static func read(from url: URL = fileURL) -> AgentStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentStatus.self, from: data)
    }

    public static func remove(at url: URL = fileURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The status of a live agent process, or nil if none. Stale files left by a crashed agent are ignored,
    /// including when its pid has been reused by another program.
    public static func live(from url: URL = fileURL) -> AgentStatus? {
        guard let status = read(from: url), executableName(of: status.pid) == "Jumphertz" else { return nil }
        return status
    }

    /// Pid of a live agent whose status file this version cannot decode (an older or newer Jumphertz).
    public static func liveAgentOfAnotherVersion(from url: URL = fileURL) -> Int32? {
        guard read(from: url) == nil, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              executableName(of: pid) == "Jumphertz" else { return nil }
        return pid
    }

    static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
