import CoreAudio
import Foundation

public struct HALError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String { "\(operation) failed (\(HALError.fourCC(status)))" }

    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return String(status)
    }
}

/// Thin typed wrappers over the AudioObject property API. Control thread only.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw HALError(status, "get '\(fourCC(address.mSelector))' on \(object)") }
        return value
    }

    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw HALError(status, "set '\(fourCC(address.mSelector))' on \(object)") }
    }

    static func getArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of: T.Type) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw HALError(status, "size of '\(fourCC(address.mSelector))'") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        guard status == noErr else { throw HALError(status, "get '\(fourCC(address.mSelector))'") }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// CF-typed properties are returned at +1.
    static func getCF<T: AnyObject>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type) throws -> T? {
        var address = address
        var value: Unmanaged<T>?
        var size = UInt32(MemoryLayout<Unmanaged<T>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw HALError(status, "get '\(fourCC(address.mSelector))' on \(object)") }
        return value?.takeRetainedValue()
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        (try? getCF(object, address(selector), as: CFString.self)).flatMap { $0 as String? }
    }

    /// Channels per buffer of the device's stream configuration for one scope.
    static func channelsPerBuffer(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw HALError(status, "size of stream configuration") }
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw)
        guard status == noErr else { throw HALError(status, "get stream configuration") }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        try getArray(device, address(kAudioDevicePropertyStreams, scope), of: AudioStreamID.self).count
    }

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }

    static func availableSampleRates(_ device: AudioObjectID) -> [AudioValueRange] {
        (try? getArray(device, address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
    }

    static func classID(_ object: AudioObjectID) -> AudioClassID {
        (try? get(object, address(kAudioObjectPropertyClass), initial: AudioClassID(0))) ?? 0
    }

    static func deviceIDs() -> [AudioObjectID] {
        (try? getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices),
                       of: AudioObjectID.self)) ?? []
    }

    static func fourCC(_ code: UInt32) -> String {
        HALError.fourCC(OSStatus(bitPattern: code)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }
}
