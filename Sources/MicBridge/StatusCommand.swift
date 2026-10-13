import AppKit
import MicBridgeCore

enum StatusCommand {
    static let launchAgentLabel = "com.zeropablo.micbridge"

    static func run() {
        let status = StatusStore.live()
        let loaded = launchAgentLoaded()

        if let status {
            print("Agent:        running (pid \(status.pid), v\(status.version))")
        } else {
            print("Agent:        not running")
        }
        print("LaunchAgent:  \(loaded ? "loaded" : "not loaded") (gui/\(getuid())/\(launchAgentLabel))")

        // Discord is checked live; it does not depend on the agent.
        let discord = NSWorkspace.shared.runningApplications
            .filter { DiscordApps.isDiscord(bundleID: $0.bundleIdentifier) }
            .compactMap { $0.localizedName ?? $0.bundleIdentifier }
        print("Discord:      \(discord.isEmpty ? "not running" : "running (\(discord.joined(separator: ", ")))")")

        guard let status else {
            if !loaded {
                print("\nThe agent is not installed or not loaded. Run scripts/install.sh.")
            }
            return
        }

        print("Microphone:   \(describe(status.permission))")
        print("State:        \(status.state.rawValue)\(status.message.map { " — \($0)" } ?? "")")
        if let bridge = status.bridge {
            print("Bridge:       active")
            print("  Input:      \(bridge.inputName), channel \(bridge.inputChannel)")
            print("  Output:     \(bridge.outputName) (L+R)")
            print("  Rate:       \(Int(bridge.sampleRate)) Hz, buffer \(bridge.bufferFrames.map(String.init) ?? "?") frames, gain \(String(format: "%+.1f", bridge.gainDb)) dB")
        } else {
            print("Bridge:       inactive")
        }
        for warning in status.warnings { print("! \(warning)") }
    }

    static func describe(_ permission: MicPermission) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "DENIED — System Settings › Privacy & Security › Microphone › MicBridge"
        case .notDetermined: return "not requested yet"
        }
    }

    static func launchAgentLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(launchAgentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
