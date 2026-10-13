import Foundation
import MicBridgeCore

/// Estimated latency added by the bridge, from the HAL-reported latencies of both ends.
enum LatencyCommand {
    static func run() {
        let system = CoreAudioSystem()
        let config = DeviceResolution.config()
        let (input, output) = DeviceResolution.resolve(system: system, config: config, quiet: true)
        let latency = system.latency(input: input, output: output, bufferFrames: config.bufferFrames)
        let rate = latency.sampleRate

        func ms(_ frames: Int) -> String { String(format: "%6.2f ms", BridgeLatency.milliseconds(frames, sampleRate: rate)) }
        func row(_ label: String, _ c: LatencyComponents) -> String {
            label.padding(toLength: 28, withPad: " ", startingAt: 0)
                + [c.deviceLatency, c.safetyOffset, c.streamLatency, c.bufferFrames, c.total]
                    .map { String($0).leftPadded(8) }.joined()
                + "  " + ms(c.total)
        }

        print("Frames @ \(Int(rate)) Hz\(config.bufferFrames != nil ? " (buffer from config bufferFrames)" : "")\n")
        print("".padding(toLength: 28, withPad: " ", startingAt: 0)
              + ["device", "safety", "stream", "buffer", "total"].map { $0.leftPadded(8) }.joined())
        print(row("\(input.name) (in)", latency.input))
        print(row("\(output.name) (out)", latency.output))
        print("")
        print("Bridge latency: \(latency.totalFrames) frames = \(String(format: "%.2f", latency.totalMilliseconds)) ms")
        print("""

            Not included: Discord's own input buffering and voice processing (and, in Discord's mic test,
            the playback path back to your headphones).
            """)
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
