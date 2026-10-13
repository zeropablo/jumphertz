import Foundation
import MicBridgeCore

/// Latency of the bridge, measured from the HAL timestamps of both IO cycles: for each output cycle, the
/// presentation time of its first frame minus the capture time of the input sample it is made from.
/// Taken from the running agent when it bridges; otherwise from a short temporary bridge.
enum LatencyCommand {
    static let settleSeconds: TimeInterval = 2
    static let measureSeconds: TimeInterval = 4

    static func run() {
        let system = CoreAudioSystem()
        let config = DeviceResolution.config()
        let (inputDevice, outputDevice) = DeviceResolution.resolve(system: system, config: config, quiet: true)
        let components = system.latencyComponents(input: inputDevice, output: outputDevice)

        let measured: (mean: Double, min: Double, max: Double, samples: UInt64, target: Int, rate: Double, source: String)
        if let agent = StatusStore.live(), agent.bridging {
            guard let window = agent.latency, let resampler = agent.resampler else {
                fail("the agent has not published a latency measurement yet; try again in a few seconds")
            }
            let age = Int(Date().timeIntervalSince(agent.updatedAt))
            measured = (window.meanMs, window.minMs, window.maxMs, window.samples, resampler.targetFill,
                        resampler.inputRate, "running agent, last 5 s window, published \(age) s ago")
        } else if let pid = StatusStore.liveAgentOfAnotherVersion() {
            fail("a MicBridge agent of another version is running (pid \(pid)). Reinstall first (scripts/install.sh).")
        } else {
            print("Agent not bridging: measuring with a temporary bridge for \(Int(settleSeconds + measureSeconds)) s…")
            let output = system.makeOutputLeg(device: outputDevice, options: config.outputOptions)
            do { try output.start() } catch { fail(String(describing: error)) }
            let input = system.makeInputLeg(device: inputDevice, inputChannel: config.inputChannel, gainDb: config.gainDb,
                                            bufferFrames: config.bufferFrames, output: output)
            do { try input.start() } catch {
                output.stop()
                fail(String(describing: error))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(settleSeconds))
            output.resetLatencyWindow()
            RunLoop.main.run(until: Date().addingTimeInterval(measureSeconds))
            let stats = output.stats
            input.stop()
            output.stop()
            guard stats.latencyCount > 0 else {
                fail("no measurement: the HAL did not provide usable timestamps (state \(stats.state.rawValue))")
            }
            measured = (stats.latencyMean * 1000, stats.latencyMin * 1000, stats.latencyMax * 1000, stats.latencyCount,
                        stats.targetFill, stats.inputRate, "temporary bridge, \(Int(measureSeconds)) s")
        }

        // The HAL timestamps start at the converter's output; add the interface's own converter latency.
        let converterFrames = components.input.deviceLatency + components.input.streamLatency
        let converterMs = BridgeLatency.milliseconds(converterFrames, sampleRate: components.sampleRate)

        print("Measured (\(measured.source)):")
        print(String(format: "  %@ capture → %@: mean %.2f ms, min %.2f, max %.2f (%llu cycles)",
                     inputDevice.name, outputDevice.name, measured.mean, measured.min, measured.max, measured.samples))
        print(String(format: "  + %@ converter latency (HAL): %d frames = %.2f ms", inputDevice.name, converterFrames, converterMs))
        print(String(format: "  = %.1f ms from the microphone into Discord's input (Discord's own processing not included)",
                     measured.mean + converterMs))
        if measured.rate > 0 {
            print(String(format: "  of which ring target: %d frames = %.2f ms", measured.target,
                         Double(measured.target) / measured.rate * 1000))
        }

        print("\nHAL-reported components (frames @ \(Int(components.sampleRate)) Hz):")
        print("".padding(toLength: 28, withPad: " ", startingAt: 0)
              + ["device", "safety", "stream", "buffer"].map { $0.leftPadded(8) }.joined())
        for (label, c) in [("\(inputDevice.name) (in)", components.input), ("\(outputDevice.name) (out)", components.output)] {
            print(label.padding(toLength: 28, withPad: " ", startingAt: 0)
                  + [c.deviceLatency, c.safetyOffset, c.streamLatency, c.bufferFrames].map { String($0).leftPadded(8) }.joined())
        }
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
