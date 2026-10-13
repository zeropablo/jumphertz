import Foundation
import Testing

/// End-to-end: the real binary, invoked as `jh` found through PATH (a symlink in another directory), from an
/// unrelated working directory — the situation where argv[0] cannot be resolved.
struct DiagnoseCLITests {
    /// The `Jumphertz` executable built next to this test bundle.
    static var binary: URL {
        let products = Bundle.allBundles.map(\.bundleURL).first { $0.pathExtension == "xctest" }?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/debug")
        return products.appendingPathComponent("Jumphertz")
    }

    @Test func diagnoseThroughASymlinkFromAnotherDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jumphertz-cli-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin"), cwd = root.appendingPathComponent("elsewhere"),
            out = root.appendingPathComponent("out")
        for dir in [bin, cwd, out] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let real = Self.binary.resolvingSymlinksInPath()
        #expect(FileManager.default.isExecutableFile(atPath: real.path))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("jh"), withDestinationURL: real)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["jh", "--diagnose"]                       // argv[0] = "jh", found through PATH
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": bin.path + ":/usr/bin:/bin",
            "JUMPHERTZ_DIAGNOSE_DIR": out.path,
            "JUMPHERTZ_DIAGNOSE_LOG_LAST": "1m",
        ]) { $1 }
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        let report = try String(contentsOf: try #require(files.first { $0.lastPathComponent.hasPrefix("jumphertz-diagnose-") }),
                                encoding: .utf8)
        #expect(!report.contains("could not run"))
        #expect(report.contains("Executable:   \(real.path)"))
        #expect(!report.contains(cwd.path))
        for section in ["jumphertz --status", "jumphertz --list-devices", "jumphertz --show-config"] {
            let body = report.components(separatedBy: "==== \(section) ====\n").last?.prefix(40) ?? ""
            #expect(!body.hasPrefix("\n") && !body.isEmpty, "empty section \(section)")
        }
        #expect(report.contains(#"process == "Jumphertz""#))
    }
}
