import AppKit
import JumphertzCore
import os

private let log = Logger(subsystem: Log.subsystem, category: "agent")  // agent process only

/// Background agent started by launchd. Idle (no audio thread) until Discord runs.
final class Agent {
    private let controller: BridgeController
    private let discord = DiscordWatcher()
    private var signalSources: [DispatchSourceSignal] = []
    private var powerObservers: [NSObjectProtocol] = []
    private var configWatcher: ConfigWatcher?
    private let startupConfigError: ConfigError?

    init() {
        let (config, result) = ConfigStore.effective()
        if case let .invalid(error) = result {
            log.error("\(String(describing: error), privacy: .public); using defaults")
            startupConfigError = error
        } else {
            startupConfigError = nil
        }
        controller = BridgeController(system: CoreAudioSystem(), permission: SystemMicPermission(), config: config)
    }

    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // LSUIElement: no Dock icon, no menu bar

        log.notice("Jumphertz \(version, privacy: .public) agent started (pid \(getpid()))")
        controller.onChange = { [weak self] _ in self?.writeStatus() }
        discord.onChange = { [weak self] apps in self?.controller.setDiscordApps(apps) }
        if let startupConfigError { controller.rejectConfig(startupConfigError) }
        discord.start()
        observePower()
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
        configWatcher?.start()
        controller.reconcile()

        // launchctl bootout / logout send SIGTERM: stop IO, destroy the aggregate, exit 0 so that
        // KeepAlive (SuccessfulExit = false) does not restart us.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.terminate(signal: sig) }
            source.resume()
            signalSources.append(source)
        }

        app.run()
        exit(0)
    }

    /// Stop cleanly before sleep (the USB interface may vanish), rebuild on wake.
    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.controller.setSuspended(true)
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.controller.setSuspended(false)
        })
    }

    /// Valid file → applied with the least disruption; invalid → previous settings kept; deleted → defaults.
    private func reloadConfig() {
        switch ConfigStore.load() {
        case let .loaded(config):
            controller.setConfig(config)
        case .missing:
            log.notice("config.json removed: using the default settings")
            controller.setConfig(.default)
        case let .invalid(error):
            controller.rejectConfig(error)
        }
    }

    private func terminate(signal: Int32) {
        log.notice("Received signal \(signal), shutting down")
        controller.shutdown()
        StatusStore.remove()
        exit(0)
    }

    private func writeStatus() {
        do {
            try StatusStore.write(AgentStatus(controller: controller, pid: getpid(), version: version))
        } catch {
            log.error("Cannot write status: \(String(describing: error), privacy: .public)")
        }
    }
}
