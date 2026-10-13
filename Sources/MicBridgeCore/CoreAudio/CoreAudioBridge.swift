import CoreAudio
import Foundation
import MicBridgeRT

public enum BridgeError: Error, CustomStringConvertible {
    case hal(HALError)
    case routing(ChannelMapError)
    case unsupportedSampleRate(Double, output: String)
    case timeout(String)
    case allocation

    public var description: String {
        switch self {
        case let .hal(error): return error.description
        case let .routing(error): return error.description
        case let .unsupportedSampleRate(rate, output):
            return "\(output) does not support \(Int(rate)) Hz."
        case let .timeout(what): return "Timed out waiting for \(what)."
        case .allocation: return "Out of memory."
        }
    }
}

/// Private aggregate (input interface = clock main, bridge output with drift compensation) + one C IOProc.
final class CoreAudioBridge: AudioBridge {
    let input: DeviceInfo
    let output: DeviceInfo
    private(set) var sampleRate: Double = 0
    private(set) var inputChannel: Int
    private var gainDb: Double
    private let requestedBufferFrames: Int?

    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var context: OpaquePointer?
    private var aggregateInputLayout: [Int] = []
    private var running = false
    private var listeners: [PropertyListener] = []
    var onEvent: ((BridgeEvent) -> Void)?

    private static var counter = 0

    init(input: DeviceInfo, output: DeviceInfo, inputChannel: Int, gainDb: Double, bufferFrames: Int?) {
        self.input = input
        self.output = output
        self.inputChannel = inputChannel
        self.gainDb = gainDb
        self.requestedBufferFrames = bufferFrames
    }

    deinit { stop() }

    func start() throws {
        guard !running else { return }
        do {
            try build()
            running = true
        } catch {
            stop()
            throw error
        }
    }

    private func build() throws {
        // Adapt to the interface: read its current rate, never change it.
        let rate = try wrap { try HAL.nominalSampleRate(input.id) }
        sampleRate = rate
        try matchOutputRate(rate)

        Self.counter += 1
        let uid = "\(aggregateUIDPrefix).\(getpid()).\(Self.counter)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MicBridge",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: input.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 1,
                 kAudioSubDeviceDriftCompensationQualityKey: Int(kAudioAggregateDriftCompensationHighQuality)],
            ],
        ]
        var newID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr else { throw BridgeError.hal(HALError(status, "AudioHardwareCreateAggregateDevice")) }
        aggregateID = newID
        Log.audio.info("Created private aggregate \(newID) (\(uid, privacy: .public)) at \(Int(rate)) Hz")

        // The HAL finishes assembling sub-devices asynchronously.
        let expectedIn = input.inputChannels
        let expectedOut = input.outputChannels + output.outputChannels
        try waitUntil("the aggregate device to come up") {
            let ins = (try? HAL.channelsPerBuffer(newID, scope: kAudioObjectPropertyScopeInput))?.reduce(0, +) ?? 0
            let outs = (try? HAL.channelsPerBuffer(newID, scope: kAudioObjectPropertyScopeOutput))?.reduce(0, +) ?? 0
            return ins >= expectedIn && outs == expectedOut
        }

        if (try? HAL.nominalSampleRate(newID)) != rate {
            try wrap { try HAL.set(newID, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64(rate)) }
        }
        enableDriftCompensation()
        if let requestedBufferFrames { try applyBufferFrames(requestedBufferFrames) }

        let inLayout = try wrap { try HAL.channelsPerBuffer(newID, scope: kAudioObjectPropertyScopeInput) }
        let outLayout = try wrap { try HAL.channelsPerBuffer(newID, scope: kAudioObjectPropertyScopeOutput) }
        aggregateInputLayout = inLayout
        let plan: RoutingPlan
        do {
            plan = try ChannelMap.plan(aggregateInput: inLayout, aggregateOutput: outLayout,
                                       micInputs: input.inputChannels, micOutputs: input.outputChannels,
                                       sinkOutputs: output.outputChannels, inputChannel: inputChannel)
        } catch let error as ChannelMapError {
            throw BridgeError.routing(error)
        }
        Log.audio.debug("Aggregate layout in=\(inLayout, privacy: .public) out=\(outLayout, privacy: .public)")

        guard let ctx = mb_context_create() else { throw BridgeError.allocation }
        context = ctx
        mb_context_set_source(ctx, MBChannelRef(buffer: UInt32(plan.source.buffer), channel: UInt32(plan.source.channel)))
        let refs = plan.destinations.map { MBChannelRef(buffer: UInt32($0.buffer), channel: UInt32($0.channel)) }
        refs.withUnsafeBufferPointer { mb_context_set_destinations(ctx, $0.baseAddress!, UInt32($0.count)) }
        mb_context_set_gain(ctx, Config.linearGain(dB: gainDb))

        var proc: AudioDeviceIOProcID?
        let procStatus = mb_create_ioproc(newID, ctx, &proc)
        guard procStatus == noErr, let proc else {
            throw BridgeError.hal(HALError(procStatus, "AudioDeviceCreateIOProcID"))
        }
        procID = proc

        try setStreamUsage(proc, input: true, enabled: plan.inputStreamsEnabled)
        try setStreamUsage(proc, input: false, enabled: plan.outputStreamsEnabled)

        let startStatus = AudioDeviceStart(newID, proc)
        guard startStatus == noErr else { throw BridgeError.hal(HALError(startStatus, "AudioDeviceStart")) }

        installListeners(aggregate: newID)

        if let after = try? HAL.nominalSampleRate(input.id), after != rate {
            Log.audio.error("Input interface rate changed during setup (\(Int(rate)) -> \(Int(after)) Hz)")
        }
        Log.audio.info("Bridge running: \(self.input.name, privacy: .public) ch \(self.inputChannel) -> \(self.output.name, privacy: .public)")
    }

    func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { Log.audio.error("AudioHardwareDestroyAggregateDevice failed: \(status)") }
            else { Log.audio.info("Destroyed private aggregate \(self.aggregateID)") }
        }
        aggregateID = 0
        // The IOProc has been destroyed, nothing references the context anymore.
        if let context { mb_context_destroy(context) }
        context = nil
        running = false
    }

    func setInputChannel(_ channel: Int) throws {
        guard channel >= 1, channel <= input.inputChannels else {
            throw BridgeError.routing(.inputChannelOutOfRange(requested: channel, available: input.inputChannels))
        }
        inputChannel = channel
        guard let context else { return }
        guard let loc = ChannelMap.locate(globalChannel: channel - 1, channelsPerBuffer: aggregateInputLayout) else {
            throw BridgeError.routing(.layoutMismatch("cannot locate input channel \(channel)"))
        }
        mb_context_set_source(context, MBChannelRef(buffer: UInt32(loc.buffer), channel: UInt32(loc.channel)))
    }

    func setGain(dB: Double) {
        gainDb = dB
        if let context { mb_context_set_gain(context, Config.linearGain(dB: dB)) }
    }

    func takePeak() -> Float { context.map { mb_context_take_peak($0) } ?? 0 }
    var cycleCount: UInt64 { context.map { mb_context_cycle_count($0) } ?? 0 }
    var signalCycleCount: UInt64 { context.map { mb_context_signal_cycle_count($0) } ?? 0 }
    var clipCount: UInt64 { context.map { mb_context_clip_count($0) } ?? 0 }
    var lastCycleFrames: Int { context.map { Int(mb_context_last_frames($0)) } ?? 0 }
    var bufferFrameSize: Int? {
        guard aggregateID != 0 else { return nil }
        return (try? HAL.get(aggregateID, HAL.address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0)))
            .map(Int.init)
    }

    // MARK: - Helpers

    /// Rate and liveness of both real devices, liveness and overloads of the aggregate. Callbacks only
    /// forward to `onEvent`; the controller decides what to do after debouncing.
    private func installListeners(aggregate: AudioObjectID) {
        for device in [input, output] {
            let id = device.id, name = device.name
            listeners += [
                PropertyListener(id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    let rate = (try? HAL.nominalSampleRate(id)) ?? 0
                    self?.onEvent?(.sampleRateChanged(device: name, rate: rate))
                },
                PropertyListener(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                    self?.onEvent?(.deviceDied(device: name))
                },
            ].compactMap { $0 }
        }
        listeners += [
            PropertyListener(aggregate, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                self?.onEvent?(.deviceDied(device: "MicBridge aggregate"))
            },
            PropertyListener(aggregate, kAudioDeviceProcessorOverload) { [weak self] in
                self?.onEvent?(.overload)
            },
        ].compactMap { $0 }
    }

    /// The aggregate needs every sub-device at the same nominal rate. We may change the bridge output
    /// (a virtual device), never the input interface.
    private func matchOutputRate(_ rate: Double) throws {
        let current = try wrap { try HAL.nominalSampleRate(output.id) }
        guard current != rate else { return }
        let supported = HAL.availableSampleRates(output.id).contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
        guard supported else { throw BridgeError.unsupportedSampleRate(rate, output: output.name) }
        Log.audio.info("Setting \(self.output.name, privacy: .public) to \(Int(rate)) Hz (was \(Int(current)) Hz)")
        try wrap { try HAL.set(output.id, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64(rate)) }
        try waitUntil("\(output.name) to switch to \(Int(rate)) Hz") {
            (try? HAL.nominalSampleRate(self.output.id)) == rate
        }
    }

    /// Only when configured. The HAL runs a device at the smallest buffer any client requests, so this
    /// also changes the Scarlett's IO cycle for other apps while the bridge runs.
    private func applyBufferFrames(_ requested: Int) throws {
        var frames = UInt32(requested)
        if let range = try? HAL.get(aggregateID, HAL.address(kAudioDevicePropertyBufferFrameSizeRange),
                                    initial: AudioValueRange(mMinimum: 0, mMaximum: 0)),
           range.mMaximum > 0 {
            let clamped = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
            if clamped != frames {
                Log.audio.warning("bufferFrames \(requested) outside \(Int(range.mMinimum))...\(Int(range.mMaximum)); using \(clamped)")
                frames = clamped
            }
        }
        Log.audio.warning("bufferFrames=\(frames) requested on the aggregate: this also applies to \(self.input.name, privacy: .public) for other apps while the bridge runs")
        try wrap { try HAL.set(aggregateID, HAL.address(kAudioDevicePropertyBufferFrameSize), frames) }
    }

    /// Belt and braces: the description key is not always honoured, so also set it on the sub-device object.
    private func enableDriftCompensation() {
        let subs = (try? HAL.getArray(aggregateID, HAL.address(kAudioObjectPropertyOwnedObjects),
                                      of: AudioObjectID.self)) ?? []
        for sub in subs where HAL.classID(sub) == kAudioSubDeviceClassID {
            guard HAL.string(sub, kAudioDevicePropertyDeviceUID) == output.uid else { continue }
            do {
                try HAL.set(sub, HAL.address(kAudioSubDevicePropertyDriftCompensation), UInt32(1))
                try HAL.set(sub, HAL.address(kAudioSubDevicePropertyDriftCompensationQuality),
                            UInt32(kAudioAggregateDriftCompensationHighQuality))
            } catch {
                Log.audio.error("Cannot enable drift compensation: \(String(describing: error), privacy: .public)")
            }
            return
        }
        Log.audio.error("Bridge output sub-device not found in aggregate; drift compensation not confirmed")
    }

    private func setStreamUsage(_ proc: AudioDeviceIOProcID, input: Bool, enabled: [Bool]) throws {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let streams = try wrap { try HAL.streamCount(aggregateID, scope: scope) }
        guard streams == enabled.count else {
            Log.audio.error("Stream count mismatch (\(streams) vs \(enabled.count)); leaving all streams enabled")
            return
        }
        let flags = enabled.map { UInt8($0 ? 1 : 0) }
        let status = flags.withUnsafeBufferPointer {
            mb_set_stream_usage(aggregateID, proc, input, $0.baseAddress!, UInt32($0.count))
        }
        if status != noErr { Log.audio.error("IOProcStreamUsage failed: \(status); continuing with all streams") }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw BridgeError.timeout(what) }
            usleep(10_000)
        }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as HALError { throw BridgeError.hal(error) }
    }
}
