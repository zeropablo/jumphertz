import Foundation
import MicBridgeCore

let version = "0.2.0"

let usage = """
    MicBridge \(version) — routes a Focusrite Scarlett input to BlackHole for Discord.

    Usage:
      micbridge --status                Agent, Discord and bridge state
      micbridge --list-devices          List Scarlett and BlackHole devices
      micbridge --latency               Estimated latency added by the bridge
      micbridge --test [options]        Run the bridge for 10 s with a VU meter and IO diagnostics
          --seconds N                     Duration (default 10); Ctrl-C stops early
          --channel N                     Input channel override (1-based)
          --gain DB                       Gain override in dB
      micbridge --agent                 Run the background agent (started by launchd)
      micbridge --request-permission    Ask for microphone access (run through `open`, see install.sh)
      micbridge --version
      micbridge --help

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
