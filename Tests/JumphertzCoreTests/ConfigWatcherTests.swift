import Foundation
import Testing
@testable import JumphertzCore

/// The real kernel notifications on a temporary directory.
struct ConfigWatcherTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func setUp() throws -> (URL, ConfigWatcher, Counter) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jumphertz-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        let counter = Counter()
        let watcher = ConfigWatcher(file: file, queue: DispatchQueue(label: "watcher-test")) { counter.increment() }
        watcher.start()
        return (file, watcher, counter)
    }

    /// Debounce (0.2 s) plus generous slack for slow CI runners.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(1200)) }

    @Test func atomicWriteIsDetected() async throws {
        let (file, watcher, counter) = try setUp()
        defer { watcher.stop() }
        try ConfigStore.write(.default, to: file)
        try await settle()
        #expect(counter.count == 1)

        var config = Config.default
        config.gainDb = -6
        try ConfigStore.write(config, to: file)
        try await settle()
        #expect(counter.count == 2)
    }

    @Test func burstOfWritesIsHandledOnce() async throws {
        let (file, watcher, counter) = try setUp()
        defer { watcher.stop() }
        for channel in 1...10 {
            var config = Config.default
            config.inputChannel = channel
            try ConfigStore.write(config, to: file)
        }
        try await settle()
        #expect(counter.count == 1)
    }

    @Test func otherFilesInTheDirectoryAreIgnored() async throws {
        let (file, watcher, counter) = try setUp()
        defer { watcher.stop() }
        try Data("{}".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("status.json"),
                                  options: .atomic)
        try await settle()
        #expect(counter.count == 0)
    }

    @Test func deletionIsDetected() async throws {
        let (file, watcher, counter) = try setUp()
        defer { watcher.stop() }
        try ConfigStore.write(.default, to: file)
        try await settle()
        try FileManager.default.removeItem(at: file)
        try await settle()
        #expect(counter.count == 2)
    }
}
