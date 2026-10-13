import AppKit
import MicBridgeCore

enum StatusCommand {
    static let launchAgentLabel = "com.zeropablo.micbridge"

    static func run() {
        let status = StatusStore.live()
        let loaded = launchAgentLoaded()

        if let status {
            print("Agent:        running (pid \(status.pid), v\(status.version))")
        } else if let pid = StatusStore.liveAgentOfAnotherVersion() {
            print("Agent:        running (pid \(pid)), another MicBridge version: reinstall to see its state")
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
        if let output = status.output {
            print("Output:       \(output.name) @ \(Int(output.sampleRate)) Hz, IO buffer \(output.bufferFrames.map(String.init) ?? "?") frames")
        } else {
            print("Output:       inactive")
        }
        if let input = status.input {
            print("Input:        \(input.leg.name), channel \(input.channel) @ \(Int(input.leg.sampleRate)) Hz, IO buffer \(input.leg.bufferFrames.map(String.init) ?? "?") frames, gain \(String(format: "%+.1f", input.gainDb)) dB")
        } else {
            print("Input:        inactive")
        }
        if let r = status.resampler, status.output != nil {
            print(String(format: "Ring:         %@, fill %.0f / target %d frames, correction %+.1f ppm",
                         r.state.rawValue, r.estimatedFill, r.targetFill, r.correctionPPM))
        }
        if let latency = status.latency {
            print(String(format: "Latency:      %.1f ms measured (min %.1f, max %.1f; capture → output device, last 5 s)",
                         latency.meanMs, latency.minMs, latency.maxMs))
        }
        let c = status.counters
        print("Underruns:    \(c.underruns) total, \(c.underrunsSinceInputStart) since the input leg started")
        print("Overflows:    \(c.overflows) total, \(c.overflowsSinceInputStart) since the input leg started (dropped samples: \(c.droppedSamples))")
        var rebuilds = "Rebuilds:     input \(c.inputRebuilds), output \(c.outputRebuilds)"
        if let last = status.lastRecovery {
            let ago = Int(Date().timeIntervalSince(last.at))
            rebuilds += " — last: \(last.reason), recovered in \(last.milliseconds) ms (\(ago) s ago)"
        }
        print(rebuilds)
        print("Overloads:    \(c.overloads)")
        print("BlackHole format changes while Discord running: \(c.outputFormatChangesWhileDiscordRunning)")
        if c.outputFormatChangesWhileDiscordRunning > 0 {
            print("! The output device changed format \(c.outputFormatChangesWhileDiscordRunning) time(s) while Discord was running. MicBridge never does this; another app did (Audio MIDI Setup, a DAW, a Multi-Output Device). Discord may have lost its input: leave and rejoin the voice channel.")
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
