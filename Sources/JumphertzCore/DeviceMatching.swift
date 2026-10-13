import Foundation

/// Pure device selection rules. No CoreAudio access here so it can be unit tested.
public enum DeviceMatching {
    /// Default bridge output when `outputDeviceUID` is not configured. Matched by name, the UID is read at runtime.
    public static let defaultOutputName = "BlackHole 2ch"

    public static func isScarlett(_ device: DeviceInfo) -> Bool {
        !device.isAggregate
            && device.inputChannels > 0
            && device.manufacturer.range(of: "Focusrite", options: .caseInsensitive) != nil
            && device.name.range(of: "Scarlett", options: .caseInsensitive) != nil
    }

    public static func isBlackHole(_ device: DeviceInfo) -> Bool {
        !device.isAggregate
            && (device.manufacturer.range(of: "Existential Audio", options: .caseInsensitive) != nil
                || device.name.lowercased().hasPrefix("blackhole"))
    }

    public enum InputSelection: Equatable {
        case selected(DeviceInfo, warning: String?)
        /// A UID is configured but that device is not connected. We wait for it rather than picking another one.
        case configuredNotFound(uid: String)
        case noneFound
    }

    public static func selectInput(from devices: [DeviceInfo], preferredUID: String?) -> InputSelection {
        let scarletts = devices.filter(isScarlett).sorted { $0.uid < $1.uid }
        if let uid = preferredUID {
            guard let match = scarletts.first(where: { $0.uid == uid }) else { return .configuredNotFound(uid: uid) }
            return .selected(match, warning: nil)
        }
        guard let first = scarletts.first else { return .noneFound }
        let warning = scarletts.count > 1
            ? "\(scarletts.count) Scarlett interfaces found; using \"\(first.name)\" (\(first.uid)). Set deviceUID to choose another."
            : nil
        return .selected(first, warning: warning)
    }

    public enum OutputSelection: Equatable {
        case selected(DeviceInfo)
        case configuredNotFound(uid: String)
        case noneFound
    }

    public static func selectOutput(from devices: [DeviceInfo], preferredUID: String?) -> OutputSelection {
        let candidates = devices.filter { !$0.isAggregate && $0.outputChannels > 0 }
        if let uid = preferredUID {
            guard let match = candidates.first(where: { $0.uid == uid }) else { return .configuredNotFound(uid: uid) }
            return .selected(match)
        }
        let match = candidates.first {
            isBlackHole($0) && $0.name.caseInsensitiveCompare(defaultOutputName) == .orderedSame
        }
        return match.map { .selected($0) } ?? .noneFound
    }

    /// Visible aggregates / Multi-Output Devices that include `uid`. Audio routed to those also reaches the
    /// bridge output, and therefore Discord's microphone.
    public static func aggregatesContaining(_ uid: String, in aggregates: [AggregateInfo]) -> [AggregateInfo] {
        aggregates.filter { $0.subDeviceUIDs.contains(uid) }
    }

    public static func feedbackWarning(outputName: String, aggregate: AggregateInfo) -> String {
        "\"\(outputName)\" is a member of the \(aggregate.kindDescription) \"\(aggregate.name)\" (\(aggregate.uid)). "
            + "Any audio played to that device is also sent into the Discord microphone."
    }
}
