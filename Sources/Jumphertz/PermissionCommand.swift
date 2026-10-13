import Foundation
import JumphertzCore

/// `--request-permission`: run by install.sh through `open -W Jumphertz.app --args ...` so that the
/// microphone prompt is attributed to Jumphertz.app rather than to the terminal.
enum PermissionCommand {
    static func run(resultFile: String?) {
        let permission = SystemMicPermission()
        var result = permission.status
        if result == .notDetermined {
            var done = false
            permission.request { granted in
                DispatchQueue.main.async {
                    result = granted
                    done = true
                }
            }
            let deadline = Date().addingTimeInterval(300)
            while !done, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        if let resultFile {
            try? Data((result.rawValue + "\n").utf8).write(to: URL(fileURLWithPath: resultFile), options: .atomic)
        }
        print(result.rawValue)
        exit(result == .granted ? 0 : 3)
    }
}
