import Foundation
import Testing
import JumphertzRT
import JumphertzSim

/// Drives the real input stage → ring → output stage with two simulated, drifting, jittery clocks.
struct ResamplingTests {
    /// Largest sample-to-sample step of a clean 0.5 amplitude 1 kHz sine at 48 kHz (+10 %): anything above is a click.
    static let naturalStep = 0.5 * 2 * Double.pi * 1000 / 48000 * 1.1

    private func run(_ configure: (inout JHSimConfig) -> Void) -> JHSimResult {
        var config = jh_sim_default_config()
        configure(&config)
        var result = JHSimResult()
        #expect(jh_sim_run(&config, &result) == 0)
        return result
    }

    private func report(_ name: String, _ r: JHSimResult) {
        print(String(format: "%@: underruns %llu, overflows %llu, dropped %llu, fill %u..%u (target %u, mean %.1f → %.1f, estimate %.0f..%.0f), correction %.1f..%.1f ppm, fill slope %.4f ppm, max step %.4f at %.2f s, longest gap %.0f ms",
                     name, r.underruns, r.overflows, r.dropped, r.fill_min, r.fill_max, r.target_fill,
                     r.fill_mean_first_half, r.fill_mean_second_half, r.estimate_min, r.estimate_max,
                     r.correction_min_ppm, r.correction_max_ppm,
                     r.fill_slope_ppm, r.max_step, r.max_step_at, Double(r.longest_gap) / 48.0))
    }

    /// - maxSlope: drift tolerance of the fill estimate, ppm (tight for 30 min runs, looser for short ones
    ///   where the end of the integral's settling is still visible).
    private func expectSteady(_ r: JHSimResult, maxSlope: Double = 1) {
        #expect(r.underruns == 0)
        #expect(r.overflows == 0)
        #expect(r.dropped == 0)
        #expect(r.resampler_errors == 0)
        #expect(r.non_finite == 0)
        #expect(r.silent_frames_after_settle == 0)
        // Locked: the fill estimate stays on target (the raw fill also slides with the clocks' phase).
        #expect(r.estimate_max - r.estimate_min < 64)
        #expect(abs(r.fill_slope_ppm) < maxSlope)
        #expect(r.max_step < Self.naturalStep)
    }

    // MARK: Drift

    @Test func reducedMarginStillSteady() {
        let r = run {
            $0.seconds = 600
            $0.settle_seconds = 60
            $0.input_ppm = 80
            $0.jitter = 0.05           // realistic HAL scheduling, not the ±20 % stress value
            $0.tuning = jh_output_reduced_margin_tuning()
        }
        report("reduced margin, jitter 5 %", r)
        expectSteady(r, maxSlope: 0.5)
    }

    /// 30 simulated minutes, 44.1 → 48 kHz, clocks 100 ppm apart, no help from HAL rate scalars:
    /// the fill loop alone must absorb the drift.
    @Test func thirtyMinutes44to48WithoutDrift() {
        let r = run {
            $0.seconds = 1800
            $0.settle_seconds = 60
            $0.input_ppm = 80
            $0.output_ppm = -20
        }
        report("30 min 44.1→48, +80/-20 ppm, no scalars", r)
        expectSteady(r, maxSlope: 0.1)
        // Measured latency = fill estimate (the virtual write position follows the capture clock) + one output
        // block until presentation; and it does not wander.
        let expected = Double(r.target_fill) / 44100 + 512 / 48000.0
        print(String(format: "latency measured %.2f / %.2f / %.2f ms (min/mean/max), model %.2f ms",
                     r.latency_min * 1000, r.latency_mean * 1000, r.latency_max * 1000, expected * 1000))
        #expect(abs(r.latency_mean - expected) < 0.002)
        #expect(r.latency_max - r.latency_min < 0.003)
        // The correction settled on the clock mismatch (≈ +100 ppm) without oscillating.
        #expect(r.correction_max_ppm - r.correction_min_ppm < 20)
        #expect(r.correction_min_ppm > 80 && r.correction_max_ppm < 120)
    }

    @Test func thirtyMinutesWithRateScalars() {
        let r = run {
            $0.seconds = 1800
            $0.settle_seconds = 60
            $0.input_ppm = 80
            $0.output_ppm = -20
            $0.pass_rate_scalars = 1
        }
        report("30 min 44.1→48, +80/-20 ppm, scalars", r)
        expectSteady(r, maxSlope: 0.1)
        #expect(abs(r.correction_min_ppm) < 10 && abs(r.correction_max_ppm) < 10)
    }

    @Test func sameRateWithDrift() {
        for ppm in [200.0, -200.0] {
            let r = run {
                $0.input_rate = 48000
                $0.seconds = 300
                $0.settle_seconds = 90
                $0.input_ppm = ppm
            }
            report("48→48, \(ppm) ppm", r)
            expectSteady(r)
        }
    }

    @Test func downsampling96to48() {
        let r = run {
            $0.input_rate = 96000
            $0.input_block = 1024
            $0.seconds = 300
            $0.settle_seconds = 90
            $0.input_ppm = -50
        }
        report("96→48, -50 ppm", r)
        expectSteady(r)
    }

    @Test func differentBlockSizes() {
        let r = run {
            $0.input_block = 1024      // e.g. Logic set a large buffer on the interface
            $0.output_block = 256
            $0.seconds = 300
            $0.settle_seconds = 90
            $0.input_ppm = 50
        }
        report("blocks 1024 → 256", r)
        expectSteady(r)
    }

    // MARK: Quality

    private func capture(seconds: Double, rate: Double = 48000, _ configure: (inout JHSimConfig) -> Void) -> [Float] {
        let count = Int(seconds * rate)
        var buffer = [Float](repeating: 0, count: count)
        buffer.withUnsafeMutableBufferPointer { pointer in
            let r = run {
                configure(&$0)
                $0.capture = pointer.baseAddress
                $0.capture_capacity = UInt64(count)
            }
            report("capture", r)
        }
        return buffer
    }

    @Test func sine44to48() {
        let x = capture(seconds: 5) {
            $0.seconds = 20
            $0.settle_seconds = 10
            $0.capture_from = 12
        }
        var frequency = 0.0, deviation = 0.0
        let thdn = jh_analysis_windowed_thdn(x, UInt64(x.count), 48000, 1000, 12000, &frequency, &deviation)
        let level = jh_analysis_tone_level(x, UInt64(x.count), 48000, 1000)
        print(String(format: "sine 44.1→48: worst THD+N %.1f dB (0.25 s windows), frequency %.5f Hz, window deviation %.2f ppm, level %.3f dBFS",
                     thdn, frequency, deviation, level))
        #expect(thdn < -80)
        #expect(abs(frequency - 1000) < 0.01)       // 10 ppm
        #expect(deviation < 10)
        #expect(abs(level - 20 * log10(0.5)) < 0.1)
    }

    @Test func passbandUpTo18k() {
        for tone in [100.0, 5000, 12000, 18000] {
            let x = capture(seconds: 2) {
                $0.seconds = 14
                $0.settle_seconds = 10
                $0.capture_from = 11
                $0.tone_hz = tone
            }
            let level = jh_analysis_tone_level(x, UInt64(x.count), 48000, tone)
            print(String(format: "passband 44.1→48 %.0f Hz: %.2f dB re input", tone, level - 20 * log10(0.5)))
            #expect(abs(level - 20 * log10(0.5)) < 0.5)
        }
    }

    /// Downsampling: tones above the output Nyquist must not fold back into the audio band.
    @Test func noAliasing96to48() {
        for (tone, alias) in [(30000.0, 18000.0), (26000, 22000), (40000, 8000)] {
            let x = capture(seconds: 2) {
                $0.input_rate = 96000
                $0.input_block = 1024
                $0.seconds = 14
                $0.settle_seconds = 10
                $0.capture_from = 11
                $0.tone_hz = tone
            }
            let level = jh_analysis_tone_level(x, UInt64(x.count), 48000, alias)
            print(String(format: "96→48 tone %.0f Hz → alias at %.0f Hz: %.1f dBFS", tone, alias, level))
            #expect(level < -80)
        }
    }

    // MARK: Disturbances

    /// Interface unplugged for 2 s: fade to silence, refill, fade back in. No click, no garbage.
    @Test func producerUnderrun() {
        let r = run {
            $0.input_rate = 48000
            $0.seconds = 60
            $0.settle_seconds = 15
            $0.producer_pause_at = 20
            $0.producer_pause_seconds = 2
        }
        report("underrun (input paused 2 s)", r)
        #expect(r.underruns == 1)
        #expect(r.non_finite == 0)
        #expect(r.max_step < Self.naturalStep)
        #expect(r.silent_frames_after_settle == 0)
        #expect(Double(r.longest_gap) / 48000 < 2.1)
    }

    /// Output stalled for 2 s while the input keeps writing: the ring overflows, the backlog is dropped.
    @Test func consumerOverflow() {
        let r = run {
            $0.seconds = 60
            $0.settle_seconds = 15
            $0.consumer_pause_at = 20
            $0.consumer_pause_seconds = 2
        }
        report("overflow (output paused 2 s)", r)
        #expect(r.dropped > 0)
        #expect(r.overflows == 1)
        #expect(r.non_finite == 0)
        #expect(r.max_step < Self.naturalStep)
        #expect(r.silent_frames_after_settle == 0)
    }

    /// Input side rebuilt from 48 to 44.1 kHz (Logic opening a project) while the output keeps running at
    /// 48 kHz: short gap, then the same tone at the right pitch.
    @Test func inputRateChangeMidStream() {
        let count = 4 * 48000
        var buffer = [Float](repeating: 0, count: count)
        var result = JHSimResult()
        buffer.withUnsafeMutableBufferPointer { pointer in
            var config = jh_sim_default_config()
            config.input_rate = 48000
            config.seconds = 40
            config.settle_seconds = 10
            config.rate_change_at = 20
            config.rate_change_gap = 0.65      // stop, debounce, rebuild
            config.new_input_rate = 44100
            config.capture = pointer.baseAddress
            config.capture_capacity = UInt64(count)
            config.capture_from = 30
            #expect(jh_sim_run(&config, &result) == 0)
        }
        report("rate change 48 → 44.1 kHz", result)
        #expect(result.underruns == 0)
        #expect(result.non_finite == 0)
        #expect(result.max_step < Self.naturalStep)
        #expect(Double(result.longest_gap) / 48000 < 0.65 + 0.1)
        #expect(result.output_frames >= UInt64(40 * 48000 - 2 * 512))   // the output never stopped
        var frequency = 0.0, deviation = 0.0
        let thdn = jh_analysis_windowed_thdn(buffer, UInt64(count), 48000, 1000, 12000, &frequency, &deviation)
        print(String(format: "after rate change: frequency %.5f Hz, worst THD+N %.1f dB, window deviation %.2f ppm",
                     frequency, thdn, deviation))
        #expect(abs(frequency - 1000) < 0.01)
        #expect(thdn < -80)
    }
}
