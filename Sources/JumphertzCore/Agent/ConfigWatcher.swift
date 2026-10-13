import Foundation

/// Watches config.json for changes made by `jumphertz --set-…` or by hand.
///
/// Watches the directory, not the file: an atomic write replaces the file (new inode), which a watch on the
/// old file would miss. Event driven (kqueue), no polling: nothing runs while nothing changes. Other files in
/// the directory (status.json) also produce events; they are filtered out by comparing the config file's
/// identity (inode, size, modification time).
public final class ConfigWatcher {
    public static let debounceInterval: TimeInterval = 0.2

    private let directory: URL
    private let file: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var lastIdentity: FileIdentity?

    struct FileIdentity: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: timespec

        static func == (a: FileIdentity, b: FileIdentity) -> Bool {
            a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    /// `onChange` runs on `queue` after the file was created, replaced, modified or deleted.
    public init(file: URL = Paths.configFile, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.file = file
        directory = file.deletingLastPathComponent()
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.controller.error("Cannot watch \(self.directory.path, privacy: .public) for configuration changes")
            return
        }
        lastIdentity = identity()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .extend],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func check() {
        pending = nil
        let current = identity()
        guard current != lastIdentity else { return }
        lastIdentity = current
        onChange()
    }

    private func identity() -> FileIdentity? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return FileIdentity(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: info.st_mtimespec)
    }
}
