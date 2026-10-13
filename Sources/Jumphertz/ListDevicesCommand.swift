import Foundation
import JumphertzCore

enum ListDevicesCommand {
    static func run() {
        let system = CoreAudioSystem()
        let devices = system.devices()
        let (config, configResult) = ConfigStore.effective()

        print("Config: \(ConfigCommand.displayPath(Paths.configFile)) — \(describe(configResult))")
        print("  inputChannel \(config.inputChannel), gain \(String(format: "%+.1f", config.gainDb)) dB, "
              + "device \(config.deviceUID.map { "\"\($0)\"" } ?? "auto"), output \(config.outputDeviceUID.map { "\"\($0)\"" } ?? "auto")")
        print("  (jumphertz --show-config for details)\n")

        let inputSelection = DeviceMatching.selectInput(from: devices, preferredUID: config.deviceUID)
        var selectedInputUID: String?
        if case let .selected(device, _) = inputSelection { selectedInputUID = device.uid }

        let scarletts = devices.filter(DeviceMatching.isScarlett).sorted { $0.uid < $1.uid }
        print("Focusrite Scarlett interfaces:")
        if scarletts.isEmpty { print("  (none detected)") }
        for device in scarletts {
            let marker = device.uid == selectedInputUID ? "  ← bridge input" : ""
            print("  • \(device.name)\(marker)")
            print("      UID:          \(device.uid)")
            print("      Inputs:       \(device.inputChannels)   Outputs: \(device.outputChannels)")
            print("      Sample rate:  \(format(rate: device.sampleRate))")
            print("      Use it:       jumphertz --set-device \"\(device.uid)\"   (or auto)")
            print("      Channels:     jumphertz --set-channel 1…\(device.inputChannels)")
        }
        switch inputSelection {
        case let .selected(_, warning?): print("  ! \(warning)")
        case let .configuredNotFound(uid): print("  ! Configured deviceUID \"\(uid)\" is not connected.")
        default: break
        }

        let outputSelection = DeviceMatching.selectOutput(from: devices, preferredUID: config.outputDeviceUID)
        var selectedOutput: DeviceInfo?
        if case let .selected(device) = outputSelection { selectedOutput = device }

        print("\nBlackHole devices:")
        let blackHoles = devices.filter(DeviceMatching.isBlackHole).sorted { $0.name < $1.name }
        if blackHoles.isEmpty { print("  (none installed — brew install blackhole-2ch)") }
        for device in blackHoles {
            let marker = device.uid == selectedOutput?.uid ? "  ← bridge output" : ""
            print("  • \(device.name)\(marker)")
            print("      UID:          \(device.uid)")
            print("      Channels:     in \(device.inputChannels) / out \(device.outputChannels)")
            print("      Sample rate:  \(format(rate: device.sampleRate))")
            print("      Use it:       jumphertz --set-output \"\(device.uid)\"   (or auto = BlackHole 2ch)")
        }
        if let selectedOutput, !DeviceMatching.isBlackHole(selectedOutput) {
            print("  Bridge output (outputDeviceUID): \(selectedOutput.name) — \(selectedOutput.uid)")
        }
        switch outputSelection {
        case let .configuredNotFound(uid): print("  ! Configured outputDeviceUID \"\(uid)\" is not present.")
        case .noneFound: print("  ! \"\(DeviceMatching.defaultOutputName)\" not found.")
        case .selected: break
        }

        if let selectedOutput {
            let hits = DeviceMatching.aggregatesContaining(selectedOutput.uid, in: system.visibleAggregates())
            if !hits.isEmpty {
                print("\nWarnings:")
                for aggregate in hits {
                    print("  ! \(DeviceMatching.feedbackWarning(outputName: selectedOutput.name, aggregate: aggregate))")
                }
            }
        }
    }

    static func describe(_ result: ConfigStore.LoadResult) -> String {
        switch result {
        case .loaded: return "loaded"
        case .missing: return "not found, using defaults"
        case let .invalid(error): return "INVALID, using defaults (\(error))"
        }
    }

    static func format(rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate)) Hz" : String(format: "%.1f Hz", rate)
    }
}
