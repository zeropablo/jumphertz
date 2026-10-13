import Foundation
import Testing
import JumphertzSim

/// The measurement tools themselves, on synthetic signals.
struct AnalysisTests {
    @Test func analysisOfAPureSine() {
        let n = 240_000
        let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        let thdn = jh_analysis_thdn(x, UInt64(n), 48000, 1000)
        let level = jh_analysis_tone_level(x, UInt64(n), 48000, 1000)
        let frequency = jh_analysis_frequency(x, UInt64(n), 48000, 1000.05)
        print(String(format: "pure sine: THD+N %.1f dB, level %.3f dB, frequency %.5f", thdn, level, frequency))
        #expect(thdn < -120)
        #expect(abs(level - 20 * log10(0.5)) < 0.01)
        #expect(abs(frequency - 1000) < 0.001)
    }
}
