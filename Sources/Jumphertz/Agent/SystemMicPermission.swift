import AVFoundation
import JumphertzCore

/// TCC microphone authorization of the process. Attributed to Jumphertz.app only when the process was
/// launched by launchd or LaunchServices; from a shell it reflects the terminal app instead.
final class SystemMicPermission: MicPermissionProviding {
    var status: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func request(_ completion: @escaping (MicPermission) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted ? .granted : .denied)
        }
    }
}
