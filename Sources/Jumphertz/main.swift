import Foundation
import JumphertzCore

let version = "1.0.1"

let usage = """
    Jumphertz \(version) — clean Focusrite Scarlett mic in Discord on macOS.

    Usage:
      jumphertz --status                Agent, Discord, bridge state, counters, measured latency
      jumphertz --list-devices          Scarlett and BlackHole devices, with the valid settings
      jumphertz --show-config           Current configuration

    Configuration (applied by the running agent within a second):
      jumphertz --set-channel N         Input channel of the Scarlett (1-based), live
      jumphertz --set-gain DB           Gain in dB, -60 to +24 (e.g. -6, +3.5), live
      jumphertz --set-device UID|auto   Scarlett to use (rebuilds the input)
      jumphertz --set-output UID|auto   BlackHole device to feed (auto = BlackHole 2ch)
      jumphertz --reset-config          Back to the defaults

    Diagnostics:
      jumphertz --diagnose              Write a report for bug reports (personal data masked)
      jumphertz --latency               Measured latency of the bridge
      jumphertz --test [options]        Run the bridge for 10 s with a VU meter and IO diagnostics
          --seconds N                     Duration (default 10); Ctrl-C stops early
          --channel N                     Input channel override (1-based)
          --gain DB                       Gain override in dB

    Internal:
      jumphertz --agent                 Run the background agent (started by launchd)
      jumphertz --request-permission    Ask for microphone access (run through `open`, see install.sh)
      jumphertz --version
      jumphertz --help

    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

/// Minimal parser: `--flag` or `--flag value`.
struct Arguments {
    private var values: [String: String] = [:]
    private(set) var command: String?

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            guard arg.hasPrefix("--") else { fail("unexpected argument \"\(arg)\"\n\n\(usage)") }
            if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") || Double(raw[i + 1]) != nil {
                values[arg] = raw[i + 1]
                i += 2
            } else {
                values[arg] = ""
                i += 1
            }
            if command == nil { command = arg }
        }
    }

    func has(_ flag: String) -> Bool { values[flag] != nil }

    func string(_ flag: String) -> String? {
        guard let raw = values[flag], !raw.isEmpty else { return nil }
        return raw
    }

    func int(_ flag: String) -> Int? {
        guard let raw = values[flag] else { return nil }
        guard let value = Int(raw) else { fail("\(flag) expects an integer") }
        return value
    }

    func double(_ flag: String) -> Double? {
        guard let raw = values[flag] else { return nil }
        guard let value = Double(raw), value.isFinite else { fail("\(flag) expects a number") }
        return value
    }
}

let args = Arguments(Array(CommandLine.arguments.dropFirst()))

switch args.command {
case "--agent":
    // The agent must outlive run(): its callbacks hold weak references to it.
    let agent = Agent()
    withExtendedLifetime(agent) { agent.run() }
case "--request-permission":
    PermissionCommand.run(resultFile: args.string("--result-file"))
case "--status":
    StatusCommand.run()
case "--set-channel":
    guard let channel = args.int("--set-channel") else { fail("--set-channel expects a channel number, e.g. --set-channel 2") }
    ConfigCommand.edit(.inputChannel(channel))
case "--set-gain":
    guard let raw = args.string("--set-gain") else { fail("--set-gain expects a value in dB, e.g. --set-gain -6") }
    do { ConfigCommand.edit(.gainDb(try ConfigEditing.parseGain(raw))) } catch { fail(String(describing: error)) }
case "--set-device":
    guard let raw = args.string("--set-device") else { fail("--set-device expects a UID or auto (see jumphertz --list-devices)") }
    ConfigCommand.edit(.inputDevice(ConfigEditing.parseUID(raw)))
case "--set-output":
    guard let raw = args.string("--set-output") else { fail("--set-output expects a UID or auto (see jumphertz --list-devices)") }
    ConfigCommand.edit(.outputDevice(ConfigEditing.parseUID(raw)))
case "--reset-config":
    ConfigCommand.reset()
case "--show-config":
    ConfigCommand.show()
case "--diagnose":
    DiagnoseCommand.run()
case "--list-devices":
    ListDevicesCommand.run()
case "--latency":
    LatencyCommand.run()
case "--test":
    TestCommand.run(seconds: args.int("--seconds") ?? 10,
                    channelOverride: args.int("--channel"),
                    gainOverride: args.double("--gain"))
case "--version":
    print(version)
case "--help", "-h":
    print(usage)
case nil:
    // Agent mode arrives in phase 2.
    print(usage)
default:
    fail("unknown option \(args.command!)\n\n\(usage)")
}
