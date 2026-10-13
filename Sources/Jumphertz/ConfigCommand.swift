import Foundation
import JumphertzCore

/// `--set-channel`, `--set-gain`, `--set-device`, `--set-output`, `--reset-config`, `--show-config`.
enum ConfigCommand {
    static func edit(_ edit: ConfigEdit) {
        let devices = CoreAudioSystem().devices().filter(\.isAlive)
        let outcome: ConfigEditOutcome
        do {
            let current = try ConfigStore.loadForEditing()
            outcome = try ConfigEditing.apply(edit, to: current, devices: devices)
        } catch {
            fail(String(describing: error))
        }
        guard !outcome.changes.isEmpty else {
            print("No change: the configuration already has this value.")
            return
        }
        do { try ConfigStore.write(outcome.config) } catch {
            fail("cannot write \(Paths.configFile.path): \(error.localizedDescription)")
        }

        for line in outcome.changes { print(line) }
        for warning in outcome.warnings { print("! \(warning)") }
        print(explain(outcome.effect))
        reportAgentWarnings()
    }

    static func explain(_ effect: ConfigEffect) -> String {
        guard let agent = StatusStore.live() else {
            return "The Jumphertz agent is not running: the setting applies when it starts."
        }
        guard agent.output != nil else {
            return "Saved. The agent applies it the next time the bridge starts (when Discord runs)."
        }
        switch effect {
        case .none: return "Saved."
        case .live: return "Applied live by the agent, without interruption."
        case .rebuildsInput: return "The agent rebuilds the input (about 30 ms of silence). BlackHole is not touched."
        case .rebuildsOutput:
            return "The agent moves the bridge to the new output. No device format is changed while Discord runs."
        case .startsOrStops: return "The agent starts or stops the bridge accordingly."
        }
    }

    /// The agent applies the file within ~0.2 s; show what it complained about, if anything.
    static func reportAgentWarnings() {
        guard StatusStore.live() != nil else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let status = StatusStore.live() else { return }
        for warning in status.warnings where warning.contains("config") || warning.contains("inputChannel") {
            print("! Agent: \(warning)")
        }
    }

    static func show() {
        let devices = CoreAudioSystem().devices().filter(\.isAlive)
        let (config, result) = ConfigStore.effective()
        print("Config file: \(displayPath(Paths.configFile)) — \(ListDevicesCommand.describe(result))")

        var inputNote = ""
        switch DeviceMatching.selectInput(from: devices, preferredUID: config.deviceUID) {
        case let .selected(device, _): inputNote = "→ \(device.name), \(device.inputChannels) inputs"
        case .configuredNotFound: inputNote = "→ not connected"
        case .noneFound: inputNote = "→ no Scarlett connected"
        }
        var outputNote = ""
        switch DeviceMatching.selectOutput(from: devices, preferredUID: config.outputDeviceUID) {
        case let .selected(device): outputNote = "→ \(device.name)"
        case .configuredNotFound: outputNote = "→ not present"
        case .noneFound: outputNote = "→ \(DeviceMatching.defaultOutputName) not installed"
        }

        func row(_ key: String, _ value: String, _ note: String = "") {
            print("  " + key.padding(toLength: 22, withPad: " ", startingAt: 0) + value + (note.isEmpty ? "" : "   " + note))
        }
        row("deviceUID", config.deviceUID.map { "\"\($0)\"" } ?? "auto", inputNote)
        row("outputDeviceUID", config.outputDeviceUID.map { "\"\($0)\"" } ?? "auto", outputNote)
        row("inputChannel", String(config.inputChannel))
        row("gainDb", String(format: "%+.1f dB", config.gainDb))
        row("enabled", String(config.enabled))
        row("bufferFrames", config.bufferFrames.map(String.init) ?? "default", "(interface IO buffer)")
        row("outputBufferFrames", config.outputBufferFrames.map(String.init) ?? "default", "(latency lever)")
        row("reducedLatencyMargin", String(config.reducedLatencyMargin), "(latency lever)")

        if let agent = StatusStore.live() {
            let configWarnings = agent.warnings.filter { $0.contains("config") || $0.contains("inputChannel") }
            print(configWarnings.isEmpty ? "Agent: running with this configuration." : "Agent:")
            for warning in configWarnings { print("! \(warning)") }
        } else {
            print("Agent: not running.")
        }
    }

    static func reset() {
        let devices = CoreAudioSystem().devices().filter(\.isAlive)
        // Resetting must work even when the current file is unreadable.
        let current: Config
        if case let .loaded(config) = ConfigStore.load() { current = config } else { current = .default }
        let outcome: ConfigEditOutcome
        do { outcome = try ConfigEditing.apply(.reset, to: current, devices: devices) } catch {
            fail(String(describing: error))
        }
        do { try ConfigStore.write(outcome.config) } catch {
            fail("cannot write \(Paths.configFile.path): \(error.localizedDescription)")
        }
        print("Configuration reset to the defaults (\(displayPath(Paths.configFile))).")
        for line in outcome.changes { print("  \(line)") }
        print(explain(outcome.effect == .none ? .live : outcome.effect))
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
