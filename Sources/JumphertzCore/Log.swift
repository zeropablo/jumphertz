import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "com.zeropablo.jumphertz"'
public enum Log {
    public static let subsystem = "com.zeropablo.jumphertz"
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let controller = Logger(subsystem: subsystem, category: "controller")
}
