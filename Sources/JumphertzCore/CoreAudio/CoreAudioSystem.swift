import CoreAudio
import Foundation
import os


public final class CoreAudioSystem: AudioSystem {
    public var onDevicesChanged: (() -> Void)? {
        didSet { installDeviceListListener() }
    }
    private var deviceListListener: PropertyListener?

    public init() {
        // Let the HAL dispatch its notifications on its own thread instead of the main run loop,
        // so CLI commands that never run a run loop still see devices appear (e.g. a new aggregate).
        var runLoop: UnsafeRawPointer? = nil  // a NULL CFRunLoopRef
        var address = HAL.address(kAudioHardwarePropertyRunLoop)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<UnsafeRawPointer?>.size), &runLoop)
        if status != noErr { Log.audio.error("Cannot detach HAL run loop: \(status)") }
    }

    private func installDeviceListListener() {
        guard onDevicesChanged != nil else { deviceListListener = nil; return }
        guard deviceListListener == nil else { return }
        deviceListListener = PropertyListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
            [weak self] in self?.onDevicesChanged?()
        }
    }

    public func devices() -> [DeviceInfo] {
        HAL.deviceIDs().compactMap(Self.info(for:))
    }

    static func info(for id: AudioObjectID) -> DeviceInfo? {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let inputs = (try? HAL.channelsPerBuffer(id, scope: kAudioObjectPropertyScopeInput))?.reduce(0, +) ?? 0
        let outputs = (try? HAL.channelsPerBuffer(id, scope: kAudioObjectPropertyScopeOutput))?.reduce(0, +) ?? 0
        return DeviceInfo(
            id: id,
            uid: uid,
            name: HAL.string(id, kAudioObjectPropertyName) ?? "?",
            manufacturer: HAL.string(id, kAudioObjectPropertyManufacturer) ?? "",
            inputChannels: inputs,
            outputChannels: outputs,
            sampleRate: (try? HAL.nominalSampleRate(id)) ?? 0,
            isAggregate: HAL.classID(id) == kAudioAggregateDeviceClassID,
            isAlive: ((try? HAL.get(id, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(1))) ?? 1) != 0)
    }

    public func visibleAggregates() -> [AggregateInfo] {
        HAL.deviceIDs().compactMap { id -> AggregateInfo? in
            guard HAL.classID(id) == kAudioAggregateDeviceClassID,
                  let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let composition = (try? HAL.getCF(id, HAL.address(kAudioAggregateDevicePropertyComposition),
                                              as: CFDictionary.self)) as? [String: Any]
            if (composition?[kAudioAggregateDeviceIsPrivateKey] as? Int ?? 0) != 0 { return nil }
            let subs = (try? HAL.getCF(id, HAL.address(kAudioAggregateDevicePropertyFullSubDeviceList),
                                       as: CFArray.self)) as? [String] ?? []
            return AggregateInfo(
                uid: uid,
                name: HAL.string(id, kAudioObjectPropertyName) ?? "?",
                isMultiOutput: (composition?[kAudioAggregateDeviceIsStackedKey] as? Int ?? 0) != 0,
                subDeviceUIDs: subs)
        }
    }

    public func makeOutputLeg(device: DeviceInfo, options: OutputOptions) -> OutputLeg {
        CoreAudioOutputLeg(device: device, options: options)
    }

    public func makeInputLeg(device: DeviceInfo, inputChannel: Int, gainDb: Double, bufferFrames: Int?,
                             output: OutputLeg) -> InputLeg {
        CoreAudioInputLeg(device: device, inputChannel: inputChannel, gainDb: gainDb, bufferFrames: bufferFrames,
                          output: output as! CoreAudioOutputLeg)
    }

    public func setNominalSampleRate(_ rate: Double, of device: DeviceInfo) throws {
        let supported = HAL.availableSampleRates(device.id).contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
        guard supported else {
            throw HALError(kAudioDeviceUnsupportedFormatError, "\(device.name) does not support \(Int(rate)) Hz")
        }
        try HAL.set(device.id, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    /// Interface input path + output device path, from the HAL's static properties.
    public func latencyComponents(input: DeviceInfo, output: DeviceInfo) -> BridgeLatency {
        BridgeLatency(
            input: Self.latencyComponents(input.id, scope: kAudioObjectPropertyScopeInput, bufferFrames: nil),
            output: Self.latencyComponents(output.id, scope: kAudioObjectPropertyScopeOutput, bufferFrames: nil),
            sampleRate: (try? HAL.nominalSampleRate(input.id)) ?? input.sampleRate)
    }

    static func latencyComponents(_ device: AudioObjectID, scope: AudioObjectPropertyScope,
                                  bufferFrames: Int?) -> LatencyComponents {
        func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope) -> Int {
            Int((try? HAL.get(object, HAL.address(selector, scope), initial: UInt32(0))) ?? 0)
        }
        let firstStream = (try? HAL.getArray(device, HAL.address(kAudioDevicePropertyStreams, scope),
                                             of: AudioStreamID.self))?.first
        return LatencyComponents(
            deviceLatency: frames(device, kAudioDevicePropertyLatency, scope),
            safetyOffset: frames(device, kAudioDevicePropertySafetyOffset, scope),
            streamLatency: firstStream.map { frames($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? 0,
            bufferFrames: bufferFrames ?? frames(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal))
    }
}
