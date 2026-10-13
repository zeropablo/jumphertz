import Foundation

/// Removes personal data from diagnostic text before it is shared in a public issue: user name and full name,
/// home directory paths, host name, and serial numbers embedded in device UIDs.
public struct Redactor: Sendable {
    public var userName: String
    public var fullName: String
    public var homeDirectory: String
    public var hostNames: [String]

    public init(userName: String, fullName: String, homeDirectory: String, hostNames: [String]) {
        self.userName = userName
        self.fullName = fullName
        self.homeDirectory = homeDirectory
        self.hostNames = hostNames
    }

    public static var current: Redactor {
        var hosts = [ProcessInfo.processInfo.hostName]
        if let local = Host.current().localizedName { hosts.append(local) }
        return Redactor(userName: NSUserName(), fullName: NSFullUserName(),
                        homeDirectory: NSHomeDirectory(), hostNames: hosts)
    }

    public func redact(_ text: String) -> String {
        var out = text

        // Home directory first (it contains the user name), then any other /Users/<name>.
        if !homeDirectory.isEmpty, homeDirectory != "/" { out = out.replacingOccurrences(of: homeDirectory, with: "~") }
        out = Self.replace(#"/Users/(?!Shared/)[^/\s"':]+"#, in: out, with: "/Users/<user>")

        // USB audio UIDs: AppleUSBAudioEngine:<vendor>:<product>:<serial or location>:<interfaces>
        out = Self.replace(#"(AppleUSBAudioEngine:[^:\n]*:[^:\n]*:)[^:\s\n]+"#, in: out, with: "$1<serial>")
        // Any other serial-looking token: 10+ upper-case letters and digits, with at least one of each.
        out = Self.replace(#"\b(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10,}\b"#, in: out, with: "<serial>")

        for host in hostNames.filter({ $0.count >= 3 }) {
            out = out.replacingOccurrences(of: host, with: "<host>", options: .caseInsensitive)
        }
        // Full name and short user name as whole words (short names would hit ordinary words).
        if fullName.count >= 3 { out = Self.replaceWord(fullName, in: out, with: "<user>") }
        if userName.count >= 3 { out = Self.replaceWord(userName, in: out, with: "<user>") }
        return out
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    static func replaceWord(_ word: String, in text: String, with replacement: String) -> String {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
