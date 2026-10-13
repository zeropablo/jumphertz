import Foundation

/// Snapshot of an audio device. The `id` is only valid for the current process lifetime and is never persisted.
public struct DeviceInfo: Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    public var isAggregate: Bool

    public init(id: UInt32, uid: String, name: String, manufacturer: String,
                inputChannels: Int, outputChannels: Int, sampleRate: Double, isAggregate: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.isAggregate = isAggregate
    }
}

/// A user-visible (non-private) aggregate or Multi-Output Device.
public struct AggregateInfo: Equatable, Sendable {
    public var uid: String
    public var name: String
    /// Multi-Output Devices are "stacked" aggregates.
    public var isMultiOutput: Bool
    public var subDeviceUIDs: [String]

    public init(uid: String, name: String, isMultiOutput: Bool, subDeviceUIDs: [String]) {
        self.uid = uid
        self.name = name
        self.isMultiOutput = isMultiOutput
        self.subDeviceUIDs = subDeviceUIDs
    }

    public var kindDescription: String { isMultiOutput ? "Multi-Output Device" : "Aggregate Device" }
}
