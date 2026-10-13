import Foundation
import os

/// Unified logging. Read with: /usr/bin/log show --last 1h --predicate 'subsystem == "com.zeropablo.jumphertz"'
/// Important events use .notice or above (persisted); .debug is for noise.
public enum Log {
    public static let subsystem = "com.zeropablo.jumphertz"

    /// Unit tests run the same code in the test runner: they log under a separate subsystem so that they
    /// never appear in the user's logs or in `jumphertz --diagnose`.
    static let effectiveSubsystem = ProcessInfo.processInfo.processName == "Jumphertz" ? subsystem : subsystem + ".tests"

    static let audio = Logger(subsystem: effectiveSubsystem, category: "audio")
    static let controller = Logger(subsystem: effectiveSubsystem, category: "controller")
}
