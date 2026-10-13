import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "com.zeropablo.micbridge"'
public enum Log {
    public static let subsystem = "com.zeropablo.micbridge"
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let controller = Logger(subsystem: subsystem, category: "controller")
}
