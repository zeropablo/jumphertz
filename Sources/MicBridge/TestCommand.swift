import Foundation
import MicBridgeCore

/// Runs the bridge without Discord and shows, continuously: VU meter (post-gain), aggregate buffer size,
/// measured IO cycles per second, and stalls of the IO callback.
enum TestCommand {
    /// The IO callback is considered stalled when the cycle counter has not moved for this long.
    static let stallThreshold: TimeInterval = 0.2
    static let pollInterval: TimeInterval = 0.02
    static let redrawInterval: TimeInterval = 0.1

    static func run(seconds: Int, channelOverride: Int?, gainOverride: Double?) {
        guard seconds > 0 else { fail("--seconds must be positive") }
        // Two bridges would both write into BlackHole and the signals would add up.
        if let agent = StatusStore.live(), agent.bridge != nil {
            fail("the MicBridge agent (pid \(agent.pid)) is already bridging. Quit Discord or stop the agent first:\n"
                 + "  launchctl bootout gui/$(id -u)/com.zeropablo.micbridge")
        }
        let system = CoreAudioSystem()
        var config = DeviceResolution.config()
        if let channelOverride { config.inputChannel = channelOverride }
        if let gainOverride { config.gainDb = gainOverride }
        do { try config.validate() } catch { fail(String(describing: error)) }
        let (input, output) = DeviceResolution.resolve(system: system, config: config)

        if let frames = config.bufferFrames {
            print("! bufferFrames = \(frames): while the bridge runs, \(input.name) uses this buffer size for every app.")
        }

        let bridge = system.makeBridge(input: input, output: output, inputChannel: config.inputChannel,
                                       gainDb: config.gainDb, bufferFrames: config.bufferFrames)
        do { try bridge.start() } catch { fail(String(describing: error)) }

        let rate = bridge.sampleRate
        let live = isatty(STDOUT_FILENO) != 0
        print("""
            \(input.name) input \(config.inputChannel) → \(output.name) L+R \
            @ \(Int(rate)) Hz, gain \(String(format: "%+.1f", config.gainDb)) dB, \
            aggregate buffer \(bridge.bufferFrameSize.map(String.init) ?? "?") frames
            Speak into the microphone. Ctrl-C to stop.\(live ? "\n" : "")
            """)

        // Ctrl-C ends the measurement cleanly; the summary is still printed.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var interrupted = false
        sigint.setEventHandler { interrupted = true }
        sigint.resume()

        let start = Date()
        var window: [(time: Date, cycles: UInt64)] = []   // last ~1 s of samples, for cycles/s
        var lastCycles: UInt64 = 0
        var lastCycleChange = start
        var stalled = false
        var stallCount = 0
        var longestStall: TimeInterval = 0
        var maxPeak: Float = 0
        var displayPeak: Float = 0
        var nextRedraw = start

        while !interrupted {
            let now = Date()
            if now.timeIntervalSince(start) >= Double(seconds) { break }
            RunLoop.main.run(until: now.addingTimeInterval(pollInterval))

            let t = Date()
            let cycles = bridge.cycleCount
            if cycles != lastCycles {
                if stalled {
                    let gap = t.timeIntervalSince(lastCycleChange)
                    longestStall = max(longestStall, gap)
                    message("! IO callback resumed after \(Int(gap * 1000)) ms", live: live)
                    stalled = false
                }
                lastCycles = cycles
                lastCycleChange = t
            } else if !stalled, t.timeIntervalSince(lastCycleChange) > stallThreshold {
                stalled = true
                stallCount += 1
                message("! IO callback stalled: no cycle for more than \(Int(stallThreshold * 1000)) ms", live: live)
            }

            window.append((t, cycles))
            window.removeAll { t.timeIntervalSince($0.time) > 1.0 }

            displayPeak = max(displayPeak, bridge.takePeak())
            if t >= nextRedraw {
                maxPeak = max(maxPeak, displayPeak)
                if live {
                    let status = String(format: "buf %@  %5.1f cyc/s  %5.1f/%d s",
                                        bridge.bufferFrameSize.map(String.init) ?? "?",
                                        cyclesPerSecond(window), t.timeIntervalSince(start), seconds)
                    print(clearLine + liveLine(peak: displayPeak, status: status, width: terminalWidth()),
                          terminator: "")
                    fflush(stdout)
                }
                displayPeak = 0
                nextRedraw = t.addingTimeInterval(redrawInterval)
            }
        }
        if stalled { longestStall = max(longestStall, Date().timeIntervalSince(lastCycleChange)) }

        // Read every counter at the same instant, before stop() frees the context.
        let elapsed = Date().timeIntervalSince(start)
        let cycles = bridge.cycleCount
        let signalCycles = bridge.signalCycleCount
        let clips = bridge.clipCount
        let framesPerCycle = bridge.lastCycleFrames
        let bufferFrames = bridge.bufferFrameSize ?? 0
        maxPeak = max(maxPeak, displayPeak, bridge.takePeak())
        bridge.stop()

        let measured = elapsed > 0 ? Double(cycles) / elapsed : 0
        let expected = framesPerCycle > 0 ? rate / Double(framesPerCycle) : 0

        if live { print(clearLine) }
        print(interrupted ? "Stopped by Ctrl-C after \(String(format: "%.2f", elapsed)) s." :
                            "Completed after \(String(format: "%.2f", elapsed)) s.")
        print(String(format: "IO cycles: %llu (%.2f/s, expected %.2f/s for %d frames @ %d Hz)",
                     cycles, measured, expected, framesPerCycle, Int(rate)))
        print("Cycles with signal: \(signalCycles)   Max peak: \(dbfs(maxPeak))   Clipped samples: \(clips)")
        print("Stalls > \(Int(stallThreshold * 1000)) ms: \(stallCount)" +
              (stallCount > 0 ? " (longest \(Int(longestStall * 1000)) ms)" : ""))
        // Machine-readable line, used by scripts/check-test-summary.sh.
        print(String(format: "summary: elapsed=%.3f cycles=%llu rate=%d frames=%d buffer=%d cycles_per_s=%.2f expected_per_s=%.2f clips=%llu stalls=%d interrupted=%d",
                     elapsed, cycles, Int(rate), framesPerCycle, bufferFrames, measured, expected,
                     clips, stallCount, interrupted ? 1 : 0))

        if expected > 0, elapsed > 2, abs(measured - expected) / expected > 0.05 {
            print("! Measured cycle rate differs from the expected rate by more than 5 %.")
        }
        if clips > 0 {
            print(config.gainDb > 0
                  ? "! Clipping: reduce gainDb (currently \(String(format: "%+.1f", config.gainDb)) dB) or the preamp gain."
                  : "! Clipping at the source: the Scarlett input reached full scale. Lower its preamp gain until the gain halo stays green.")
        }
        if cycles == 0 {
            fail("the audio device never ran")
        } else if signalCycles == 0 {
            print("""
                ! The input was pure digital silence. Most likely the microphone permission is denied for the \
                app that launched this command (Terminal, iTerm…): System Settings › Privacy & Security › Microphone.
                """)
            exit(2)
        }
    }

    static let clearLine = "\u{1B}[2K\r"

    /// Columns of the terminal stdout is attached to; 80 when unknown.
    static func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }

    /// One live line that never reaches the last column (which would trigger an automatic wrap and break `\r`).
    /// The meter bar shrinks first; the status text is truncated only on very narrow terminals.
    static func liveLine(peak: Float, status: String, width: Int) -> String {
        let usable = max(1, width - 1)
        let level = dbfs(peak).leftPadded(10)
        let fixed = level.count + 1 + status.count            // "<level> <status>"
        let barWidth = min(40, usable - fixed - 3)           // "[" + bar + "] "
        let line = barWidth >= 5 ? "[\(bar(peak, width: barWidth))] \(level) \(status)" : "\(level) \(status)"
        return String(line.prefix(usable))
    }

    /// Prints a one-off message without leaving a half-drawn live line behind.
    static func message(_ text: String, live: Bool) {
        print(live ? clearLine + text : text)
    }

    static func cyclesPerSecond(_ window: [(time: Date, cycles: UInt64)]) -> Double {
        guard let first = window.first, let last = window.last else { return 0 }
        let dt = last.time.timeIntervalSince(first.time)
        return dt > 0.2 ? Double(last.cycles - first.cycles) / dt : 0
    }

    static func dbfs(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "-inf dBFS"
    }

    /// `width` columns from -60 to 0 dBFS; the top 5 % is drawn with "!", the next 15 % with "=".
    static func bar(_ peak: Float, width: Int) -> String {
        let db = peak > 0 ? Double(20 * log10(peak)) : -120
        let filled = Int(((db + 60) / 60 * Double(width)).rounded()).clamped(to: 0...width)
        let hot = max(1, width / 20), warm = max(1, width * 3 / 20)
        return String((0..<width).map { i -> Character in
            guard i < filled else { return "." }
            return i >= width - hot ? "!" : (i >= width - hot - warm ? "=" : "#")
        })
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
