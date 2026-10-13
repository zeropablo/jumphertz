import Foundation
import JumphertzCore

/// Resolves the bridge input and output for CLI commands, exiting with a clear message when impossible.
enum DeviceResolution {
    static func resolve(system: AudioSystem, config: Config, quiet: Bool = false) -> (input: DeviceInfo, output: DeviceInfo) {
        let devices = system.devices()

        let input: DeviceInfo
        switch DeviceMatching.selectInput(from: devices, preferredUID: config.deviceUID) {
        case let .selected(device, warning):
            if let warning, !quiet { print("! \(warning)") }
            input = device
        case let .configuredNotFound(uid): fail("configured Scarlett \"\(uid)\" is not connected")
        case .noneFound: fail("no Focusrite Scarlett detected (see jumphertz --list-devices)")
        }

        let output: DeviceInfo
        switch DeviceMatching.selectOutput(from: devices, preferredUID: config.outputDeviceUID) {
        case let .selected(device): output = device
        case let .configuredNotFound(uid): fail("configured output device \"\(uid)\" is not present")
        case .noneFound:
            fail("\"\(DeviceMatching.defaultOutputName)\" not found — install it with: brew install blackhole-2ch")
        }

        if !quiet {
            for aggregate in DeviceMatching.aggregatesContaining(output.uid, in: system.visibleAggregates()) {
                print("! \(DeviceMatching.feedbackWarning(outputName: output.name, aggregate: aggregate))")
            }
        }
        return (input, output)
    }

    /// Effective config, reporting an invalid file.
    static func config() -> Config {
        let (config, result) = ConfigStore.effective()
        if case let .invalid(error) = result { print("! \(error) — using defaults") }
        return config
    }
}
