import CoreAudio
import Foundation
import os


/// Prefix of the UIDs of the private aggregates this process creates.
let aggregateUIDPrefix = "com.zeropablo.micbridge.aggregate"

public final class CoreAudioSystem: AudioSystem {
    public init() {
        // Let the HAL dispatch its notifications on its own thread instead of the main run loop,
        // so CLI commands that never run a run loop still see devices appear (e.g. a new aggregate).
        var runLoop: UnsafeRawPointer? = nil  // a NULL CFRunLoopRef
        var address = HAL.address(kAudioHardwarePropertyRunLoop)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<UnsafeRawPointer?>.size), &runLoop)
        if status != noErr { Log.audio.error("Cannot detach HAL run loop: \(status)") }
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
            isAggregate: HAL.classID(id) == kAudioAggregateDeviceClassID)
    }

    public func visibleAggregates() -> [AggregateInfo] {
        HAL.deviceIDs().compactMap { id -> AggregateInfo? in
            guard HAL.classID(id) == kAudioAggregateDeviceClassID,
                  let uid = HAL.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(aggregateUIDPrefix) else { return nil }
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

    public func makeBridge(input: DeviceInfo, output: DeviceInfo, inputChannel: Int, gainDb: Double,
                           bufferFrames: Int?) -> AudioBridge {
        CoreAudioBridge(input: input, output: output, inputChannel: inputChannel, gainDb: gainDb,
                        bufferFrames: bufferFrames)
    }

    /// Interface input path + bridge output path. `bufferFrames` replaces the devices' current buffer size
    /// when set (that is what the bridge would request).
    public func latency(input: DeviceInfo, output: DeviceInfo, bufferFrames: Int?) -> BridgeLatency {
        BridgeLatency(
            input: Self.latencyComponents(input.id, scope: kAudioObjectPropertyScopeInput, bufferFrames: bufferFrames),
            output: Self.latencyComponents(output.id, scope: kAudioObjectPropertyScopeOutput, bufferFrames: bufferFrames),
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
