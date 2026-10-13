import Foundation
import JumphertzCore

/// `--diagnose`: one text file for bug reports, with personal data masked. Never opens an audio device
/// (no microphone prompt): the latency comes from the running agent only.
enum DiagnoseCommand {
    /// Only the agent's own events: unit tests of older builds logged under the same subsystem.
    static let logPredicate = "subsystem == \"\(Log.subsystem)\" AND process == \"Jumphertz\""

    static func run() {
        let environment = ProcessInfo.processInfo.environment
        let stamp = DateFormatter.diagnoseStamp.string(from: Date())
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        // JUMPHERTZ_DIAGNOSE_DIR / JUMPHERTZ_DIAGNOSE_LOG_LAST: used by the tests only.
        let folder = environment["JUMPHERTZ_DIAGNOSE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (FileManager.default.fileExists(atPath: desktop.path) ? desktop : FileManager.default.homeDirectoryForCurrentUser)
        let logWindow = environment["JUMPHERTZ_DIAGNOSE_LOG_LAST"] ?? "1h"
        let file = folder.appendingPathComponent("jumphertz-diagnose-\(stamp).txt")

        print("Collecting (the system log takes a few seconds)…")
        var report = "Jumphertz diagnose — \(ISO8601DateFormatter().string(from: Date()))\n"
        report += section("System", system())
        report += section("Jumphertz", jumphertz())
        report += section("BlackHole drivers", blackHoleDrivers())
        report += section("jumphertz --status", runSelf("--status"))
        report += section("jumphertz --list-devices", runSelf("--list-devices"))
        report += section("jumphertz --show-config", runSelf("--show-config"))
        report += section("config.json", (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? "(no file: defaults)")
        report += section("Latency", latency())
        report += section("log show --last \(logWindow) (\(logPredicate))",
                          run("/usr/bin/log", ["show", "--last", logWindow, "--style", "compact",
                                               "--predicate", logPredicate], timeout: 60))

        let redacted = Redactor.current.redact(report)
        do { try redacted.write(to: file, atomically: true, encoding: .utf8) } catch {
            fail("cannot write \(file.path): \(error.localizedDescription)")
        }
        print("""
            Report written to \(ConfigCommand.displayPath(file))
            User name, home paths, host name and device serial numbers are masked. Open the file and check it
            before attaching it to a GitHub issue.
            """)
    }

    static func section(_ title: String, _ body: String) -> String {
        "\n==== \(title) ====\n" + body.trimmingCharacters(in: .newlines) + "\n"
    }

    static func system() -> String {
        let translated = sysctlInt("sysctl.proc_translated") == 1
        return """
            Mac model:    \(sysctlString("hw.model") ?? "?")
            Chip:         \(sysctlString("machdep.cpu.brand_string") ?? "?")
            Architecture: \(machine())\(translated ? " (running under Rosetta)" : "")
            macOS:        \(ProcessInfo.processInfo.operatingSystemVersionString)
            Command Line Tools: \(run("/usr/bin/xcode-select", ["-p"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    static func jumphertz() -> String {
        let executable = ExecutablePath.current
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        let signed = contents.lastPathComponent == "Contents" && bundle.pathExtension == "app" ? bundle : executable
        let signing = run("/usr/bin/codesign", ["-dv", signed.path], timeout: 10)
            .split(separator: "\n").filter { $0.hasPrefix("Identifier") || $0.hasPrefix("Signature") || $0.hasPrefix("Authority") || $0.hasPrefix("TeamIdentifier") }
            .joined(separator: "\n")
        let launchAgent = StatusCommand.launchAgentLoaded() ? "loaded" : "not loaded"
        let plist = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(StatusCommand.launchAgentLabel).plist").path)
        let permission = StatusStore.live()?.permission.rawValue ?? "unknown (agent not running)"
        return """
            Version:      \(version)
            Executable:   \(executable.path)
            \(signing)
            LaunchAgent:  \(launchAgent), plist \(plist ? "present" : "missing")
            Microphone permission (agent): \(permission)
            """
    }

    static func blackHoleDrivers() -> String {
        let folders = ["/Library/Audio/Plug-Ins/HAL",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/HAL").path]
        var lines: [String] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where name.lowercased().hasPrefix("blackhole") {
                let info = NSDictionary(contentsOfFile: "\(folder)/\(name)/Contents/Info.plist")
                lines.append("\(folder)/\(name)  version \(info?["CFBundleShortVersionString"] as? String ?? "?")")
            }
        }
        return lines.isEmpty ? "none found" : lines.joined(separator: "\n")
    }

    static func latency() -> String {
        guard let agent = StatusStore.live(), agent.bridging, let latency = agent.latency else {
            return "Not measured: the agent is not bridging (run during a call, or: jumphertz --latency)."
        }
        return String(format: "%.1f ms measured by the agent (min %.1f, max %.1f, %llu cycles)",
                      latency.meanMs, latency.minMs, latency.maxMs, latency.samples)
    }

    static func runSelf(_ argument: String) -> String {
        run(ExecutablePath.current.path, [argument], timeout: 20)
    }

    /// Output (stdout + stderr) of a command, or a note if it failed or timed out.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "(could not run \(path): \(error.localizedDescription))" }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read until EOF before waiting, so a large output cannot fill the pipe and block the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        return process.terminationReason == .uncaughtSignal ? text + "\n(timed out after \(Int(timeout)) s)" : text
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension DateFormatter {
    static let diagnoseStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// The running binary's real path. argv[0] is only what the shell was given ("jumphertz" found through PATH,
/// a symlink, a relative path); the kernel knows the actual file.
enum ExecutablePath {
    static var current: URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        }
        if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }
}
