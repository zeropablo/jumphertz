import CoreAudio
import Foundation
import JumphertzRT

public enum BridgeError: Error, CustomStringConvertible {
    case hal(HALError)
    case routing(ChannelMapError)
    case allocation

    public var description: String {
        switch self {
        case let .hal(error): return error.description
        case let .routing(error): return error.description
        case .allocation: return "Out of memory."
        }
    }
}

private func wrap<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as HALError { throw BridgeError.hal(error) }
}

/// Liveness, rate, layout and overload listeners for one device; callbacks only forward to `onEvent`.
private func deviceListeners(_ device: DeviceInfo, scope: AudioObjectPropertyScope,
                             emit: @escaping (BridgeEvent) -> Void) -> [PropertyListener] {
    let id = device.id, uid = device.uid
    return [
        PropertyListener(id, kAudioDevicePropertyNominalSampleRate) {
            emit(.sampleRateChanged(uid: uid, rate: (try? HAL.nominalSampleRate(id)) ?? 0))
        },
        PropertyListener(id, kAudioDevicePropertyStreamConfiguration, scope: scope) { emit(.formatChanged(uid: uid)) },
        PropertyListener(id, kAudioDevicePropertyDeviceIsAlive) { emit(.deviceDied(uid: uid)) },
        PropertyListener(id, kAudioDeviceProcessorOverload) { emit(.overload(uid: uid)) },
    ].compactMap { $0 }
}

/// Only when configured. The HAL runs a device at the smallest buffer any client of the process asks for.
private func requestBufferFrames(_ requested: Int, on device: DeviceInfo) throws {
    var frames = UInt32(requested)
    if let range = try? HAL.get(device.id, HAL.address(kAudioDevicePropertyBufferFrameSizeRange),
                                initial: AudioValueRange(mMinimum: 0, mMaximum: 0)), range.mMaximum > 0 {
        frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
    }
    try wrap { try HAL.set(device.id, HAL.address(kAudioDevicePropertyBufferFrameSize), frames) }
    Log.audio.notice("Requested \(frames)-frame IO buffer on \(device.name, privacy: .public)")
}

private func setStreamUsage(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) {
    let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    guard let streams = try? HAL.streamCount(device, scope: scope), streams > 0 else { return }
    let flags = (0..<streams).map { UInt8($0 < enabled.count && enabled[$0] ? 1 : 0) }
    let status = flags.withUnsafeBufferPointer {
        jh_set_stream_usage(device, proc, input, $0.baseAddress!, UInt32($0.count))
    }
    if status != noErr { Log.audio.debug("IOProcStreamUsage failed: \(status); all streams stay on") }
}

private func bufferFrameSize(of device: AudioObjectID) -> Int? {
    (try? HAL.get(device, HAL.address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0))).map(Int.init)
}

// MARK: - Output leg

/// IOProc on the output device alone. The ring and the resampling stage live as long as this object, so an
/// input leg (which keeps a strong reference to it) can never write into freed memory.
final class CoreAudioOutputLeg: OutputLeg {
    static let ringCapacity: UInt32 = 32768
    static let maxBlock: UInt32 = 8192

    let device: DeviceInfo
    let options: OutputOptions
    private(set) var sampleRate: Double = 0
    var onEvent: ((BridgeEvent) -> Void)?

    let ring: OpaquePointer
    private var stage: OpaquePointer?
    private var io: OpaquePointer?
    private var procID: AudioDeviceIOProcID?
    private var listeners: [PropertyListener] = []

    init(device: DeviceInfo, options: OutputOptions) {
        self.device = device
        self.options = options
        ring = jh_ring_create(Self.ringCapacity)!
    }

    deinit {
        stop()
        jh_ring_destroy(ring)
    }

    func start() throws {
        guard procID == nil else { return }
        do { try build() } catch {
            stop()
            throw error
        }
    }

    private func build() throws {
        // Never written: Discord may be reading this device; its format must not change.
        sampleRate = try wrap { try HAL.nominalSampleRate(device.id) }
        let tuning = options.reducedMargin ? jh_output_reduced_margin_tuning() : jh_output_default_tuning()
        guard let stage = jh_output_create(ring, sampleRate, Self.maxBlock, tuning),
              let io = jh_output_io_create(stage) else { throw BridgeError.allocation }
        self.stage = stage
        self.io = io

        let layout = try wrap { try HAL.channelsPerBuffer(device.id, scope: kAudioObjectPropertyScopeOutput) }
        let routing: OutputRouting
        do { routing = try ChannelMap.output(layout: layout) } catch let error as ChannelMapError {
            throw BridgeError.routing(error)
        }
        let refs = routing.destinations.map { JHChannelRef(buffer: UInt32($0.buffer), channel: UInt32($0.channel)) }
        refs.withUnsafeBufferPointer { jh_output_io_set_destinations(io, $0.baseAddress!, UInt32($0.count)) }

        if let frames = options.bufferFrames { try requestBufferFrames(frames, on: device) }

        var proc: AudioDeviceIOProcID?
        let status = jh_output_io_create_proc(device.id, io, &proc)
        guard status == noErr, let proc else { throw BridgeError.hal(HALError(status, "AudioDeviceCreateIOProcID")) }
        procID = proc
        setStreamUsage(device.id, proc, input: true, enabled: [])
        setStreamUsage(device.id, proc, input: false, enabled: routing.outputStreamsEnabled)

        let start = AudioDeviceStart(device.id, proc)
        guard start == noErr else { throw BridgeError.hal(HALError(start, "AudioDeviceStart")) }
        listeners = deviceListeners(device, scope: kAudioObjectPropertyScopeOutput) { [weak self] in self?.onEvent?($0) }
        Log.audio.notice("Output leg started on \(self.device.name, privacy: .public) at \(Int(self.sampleRate)) Hz (format left untouched)")
    }

    func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let procID {
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
            Log.audio.notice("Output leg stopped on \(self.device.name, privacy: .public)")
        }
        procID = nil
        // The IOProc is gone: nothing uses these anymore.
        jh_output_io_destroy(io)
        io = nil
        jh_output_destroy(stage)
        stage = nil
    }

    func setInputRate(_ rate: Double) {
        if let stage { jh_output_set_input_rate(stage, rate) }
    }

    func resetLatencyWindow() {
        if let stage { jh_output_reset_latency(stage) }
    }

    var stats: OutputStats {
        guard let stage else { return OutputStats() }
        var raw = JHOutputStats()
        jh_output_get_stats(stage, &raw)
        var s = OutputStats()
        s.state = raw.state == JHOutputStateRunning ? .running : (raw.state == JHOutputStateRefill ? .refill : .silent)
        s.inputRate = raw.input_rate
        s.outputRate = raw.output_rate
        s.fill = Int(raw.fill)
        s.estimatedFill = raw.estimated_fill
        s.targetFill = Int(raw.target_fill)
        s.correctionPPM = raw.correction_ppm
        s.cycles = io.map { jh_output_io_cycles($0) } ?? 0
        s.underruns = raw.underruns
        s.overflows = raw.overflows
        s.resamplerErrors = raw.resampler_errors
        s.latencyMean = raw.latency_mean
        s.latencyMin = raw.latency_min
        s.latencyMax = raw.latency_max
        s.latencyCount = raw.latency_count
        return s
    }

    var bufferFrameSize: Int? { procID == nil ? nil : JumphertzCore.bufferFrameSize(of: device.id) }
}

// MARK: - Input leg

/// IOProc on the interface alone, writing the selected channel into the output leg's ring.
final class CoreAudioInputLeg: InputLeg {
    let device: DeviceInfo
    private(set) var sampleRate: Double = 0
    private(set) var inputChannel: Int
    private var gainDb: Double
    private let requestedBufferFrames: Int?
    var onEvent: ((BridgeEvent) -> Void)?

    private let output: CoreAudioOutputLeg   // strong: keeps the ring alive
    private var stage: OpaquePointer?
    private var io: OpaquePointer?
    private var procID: AudioDeviceIOProcID?
    private var layout: [Int] = []
    private var listeners: [PropertyListener] = []

    init(device: DeviceInfo, inputChannel: Int, gainDb: Double, bufferFrames: Int?, output: CoreAudioOutputLeg) {
        self.device = device
        self.inputChannel = inputChannel
        self.gainDb = gainDb
        requestedBufferFrames = bufferFrames
        self.output = output
    }

    deinit { stop() }

    func start() throws {
        guard procID == nil else { return }
        do { try build() } catch {
            stop()
            throw error
        }
    }

    private func build() throws {
        // Adapt to the interface: read its rate, never change it.
        sampleRate = try wrap { try HAL.nominalSampleRate(device.id) }
        layout = try wrap { try HAL.channelsPerBuffer(device.id, scope: kAudioObjectPropertyScopeInput) }
        let routing: InputRouting
        do { routing = try ChannelMap.input(layout: layout, inputChannel: inputChannel) } catch let error as ChannelMapError {
            throw BridgeError.routing(error)
        }

        guard let stage = jh_input_create(output.ring, sampleRate), let io = jh_input_io_create(stage) else {
            throw BridgeError.allocation
        }
        self.stage = stage
        self.io = io
        jh_input_set_gain(stage, Config.linearGain(dB: gainDb))
        jh_input_io_set_source(io, JHChannelRef(buffer: UInt32(routing.source.buffer), channel: UInt32(routing.source.channel)))

        if let frames = requestedBufferFrames { try requestBufferFrames(frames, on: device) }

        var proc: AudioDeviceIOProcID?
        let status = jh_input_io_create_proc(device.id, io, &proc)
        guard status == noErr, let proc else { throw BridgeError.hal(HALError(status, "AudioDeviceCreateIOProcID")) }
        procID = proc
        setStreamUsage(device.id, proc, input: true, enabled: routing.inputStreamsEnabled)
        setStreamUsage(device.id, proc, input: false, enabled: [])

        // Announce the new stream before writing into the ring: the output fades, discards and refills.
        output.setInputRate(sampleRate)
        let start = AudioDeviceStart(device.id, proc)
        guard start == noErr else { throw BridgeError.hal(HALError(start, "AudioDeviceStart")) }
        listeners = deviceListeners(device, scope: kAudioObjectPropertyScopeInput) { [weak self] in self?.onEvent?($0) }

        if let after = try? HAL.nominalSampleRate(device.id), after != sampleRate {
            Log.audio.error("Interface rate changed during setup (\(Int(self.sampleRate)) -> \(Int(after)) Hz)")
        }
        Log.audio.notice("Input leg started: \(self.device.name, privacy: .public) channel \(self.inputChannel) at \(Int(self.sampleRate)) Hz")
    }

    func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let procID {
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
            // The output keeps running and writes silence until the next input leg.
            output.setInputRate(0)
            Log.audio.notice("Input leg stopped on \(self.device.name, privacy: .public)")
        }
        procID = nil
        jh_input_io_destroy(io)
        io = nil
        jh_input_destroy(stage)
        stage = nil
    }

    func setInputChannel(_ channel: Int) throws {
        guard channel >= 1, channel <= device.inputChannels else {
            throw BridgeError.routing(.inputChannelOutOfRange(requested: channel, available: device.inputChannels))
        }
        inputChannel = channel
        guard let io, let loc = ChannelMap.locate(globalChannel: channel - 1, channelsPerBuffer: layout) else { return }
        jh_input_io_set_source(io, JHChannelRef(buffer: UInt32(loc.buffer), channel: UInt32(loc.channel)))
    }

    func setGain(dB: Double) {
        gainDb = dB
        if let stage { jh_input_set_gain(stage, Config.linearGain(dB: dB)) }
    }

    func takePeak() -> Float { stage.map { jh_input_take_peak($0) } ?? 0 }
    var cycleCount: UInt64 { stage.map { jh_input_cycles($0) } ?? 0 }
    var signalCycleCount: UInt64 { stage.map { jh_input_signal_cycles($0) } ?? 0 }
    var clipCount: UInt64 { stage.map { jh_input_clipped_samples($0) } ?? 0 }
    var droppedSamples: UInt64 { stage.map { jh_input_dropped_samples($0) } ?? 0 }
    var lastCycleFrames: Int { stage.map { Int(jh_input_last_frames($0)) } ?? 0 }
    var bufferFrameSize: Int? { procID == nil ? nil : JumphertzCore.bufferFrameSize(of: device.id) }
}
