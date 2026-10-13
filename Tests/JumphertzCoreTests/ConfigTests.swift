import Foundation
import Testing
@testable import JumphertzCore

struct ConfigTests {
    private func parse(_ json: String) throws -> Config { try Config.parse(Data(json.utf8)) }

    @Test func fullConfig() throws {
        let config = try parse("""
            {"deviceUID": "abc", "outputDeviceUID": "BlackHole16ch_UID", "inputChannel": 3, "gainDb": -6.5,
             "enabled": false, "bufferFrames": 256, "outputBufferFrames": 128, "reducedLatencyMargin": true}
            """)
        #expect(config == Config(deviceUID: "abc", outputDeviceUID: "BlackHole16ch_UID",
                                 inputChannel: 3, gainDb: -6.5, enabled: false, bufferFrames: 256,
                                 outputBufferFrames: 128, reducedLatencyMargin: true))
    }

    @Test func missingKeysUseDefaults() throws {
        #expect(try parse("{}") == .default)
        #expect(try parse(#"{"deviceUID": null}"#) == .default)
    }

    @Test func rejectsInvalidValues() {
        #expect(throws: ConfigError.invalidValue(key: "inputChannel", reason: "must be 1 or greater")) {
            try parse(#"{"inputChannel": 0}"#)
        }
        #expect(throws: ConfigError.self) { try parse(#"{"gainDb": 40}"#) }
        #expect(throws: ConfigError.self) { try parse(#"{"deviceUID": "  "}"#) }
        #expect(throws: ConfigError.self) { try parse(#"{"inputChannel": "two"}"#) }
        #expect(throws: ConfigError.self) { try parse("not json") }
        #expect(throws: ConfigError.self) { try parse(#"{"bufferFrames": 8}"#) }
        #expect(throws: ConfigError.self) { try parse(#"{"bufferFrames": 8192}"#) }
        #expect(throws: ConfigError.self) { try parse(#"{"outputBufferFrames": 4}"#) }
        #expect(throws: ConfigError.self) { try parse(#"{"reducedLatencyMargin": "yes"}"#) }
    }

    @Test func roundTripWritesNulls() throws {
        let data = try Config.default.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""deviceUID" : null"#))
        #expect(text.contains(#""outputDeviceUID" : null"#))
        #expect(text.contains(#""bufferFrames" : null"#))
        #expect(text.contains(#""outputBufferFrames" : null"#))
        #expect(text.contains(#""reducedLatencyMargin" : false"#))
        #expect(try Config.parse(data) == .default)
    }

    @Test func linearGain() {
        #expect(Config.linearGain(dB: 0) == 1)
        #expect(abs(Config.linearGain(dB: -6) - 0.501) < 0.001)
    }
}

struct LatencyTests {
    @Test func sumsBothSides() {
        let latency = BridgeLatency(
            input: LatencyComponents(deviceLatency: 30, safetyOffset: 20, streamLatency: 10, bufferFrames: 512),
            output: LatencyComponents(deviceLatency: 0, safetyOffset: 0, streamLatency: 0, bufferFrames: 512),
            sampleRate: 48000)
        #expect(latency.totalFrames == 1084)
        #expect(abs(latency.totalMilliseconds - 22.583) < 0.001)
    }
}
