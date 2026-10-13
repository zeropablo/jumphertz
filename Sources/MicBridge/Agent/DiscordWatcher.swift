import AppKit
import MicBridgeCore

/// Tracks running Discord instances (stable, PTB, Canary) through NSWorkspace notifications.
/// Event driven: no polling.
final class DiscordWatcher {
    /// Bundle IDs currently running, called on the main thread whenever the set changes.
    var onChange: ((Set<String>) -> Void)?

    private var running: [pid_t: String] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            self?.handle(note, launched: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            self?.handle(note, launched: false)
        })
        // Discord may already be running when the agent starts (login, reinstall, crash restart).
        for app in NSWorkspace.shared.runningApplications where DiscordApps.isDiscord(bundleID: app.bundleIdentifier) {
            running[app.processIdentifier] = app.bundleIdentifier
        }
        onChange?(current)
    }

    var current: Set<String> { Set(running.values) }

    private func handle(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, DiscordApps.isDiscord(bundleID: bundleID) else { return }
        let before = current
        if launched { running[app.processIdentifier] = bundleID } else { running[app.processIdentifier] = nil }
        if current != before { onChange?(current) }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
