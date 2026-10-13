import Foundation

/// Snapshot written by the agent for `micbridge --status`.
public struct AgentStatus: Codable, Equatable, Sendable {
    public struct BridgeInfo: Codable, Equatable, Sendable {
        public var inputName: String
        public var inputUID: String
        public var inputChannel: Int
        public var outputName: String
        public var outputUID: String
        public var sampleRate: Double
        public var bufferFrames: Int?
        public var gainDb: Double
    }

    public var pid: Int32
    public var version: String
    public var state: BridgeController.State
    public var message: String?
    public var permission: MicPermission
    public var discordApps: [String]
    public var bridge: BridgeInfo?
    public var warnings: [String]
    /// Rebuilds since the agent started (sample rate, hot plug, wake, IO stall).
    public var rebuildCount: Int
    public var lastRecovery: BridgeController.Recovery?
    /// IO cycles that missed their deadline since the agent started.
    public var overloadCount: Int
    public var updatedAt: Date

    public init(controller: BridgeController, pid: Int32, version: String, now: Date = Date()) {
        self.pid = pid
        self.version = version
        state = controller.state
        message = controller.message
        permission = controller.permissionStatus
        discordApps = controller.discordApps.sorted()
        warnings = controller.warnings
        rebuildCount = controller.rebuildCount
        lastRecovery = controller.lastRecovery
        overloadCount = controller.overloadCount
        updatedAt = now
        bridge = controller.bridge.map {
            BridgeInfo(inputName: $0.input.name, inputUID: $0.input.uid, inputChannel: $0.inputChannel,
                       outputName: $0.output.name, outputUID: $0.output.uid, sampleRate: $0.sampleRate,
                       bufferFrames: $0.bufferFrameSize, gainDb: controller.config.gainDb)
        }
    }
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
        guard let status = read(from: url), executableName(of: status.pid) == "MicBridge" else { return nil }
        return status
    }

    static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
