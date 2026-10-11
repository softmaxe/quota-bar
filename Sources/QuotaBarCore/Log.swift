import Foundation
import os

/// Shared logger. `make logs` streams this subsystem.
public enum Log {
    public static let subsystem = "com.quotabar.app"

    public static let codex = Logger(subsystem: Log.subsystem, category: "codex")
    public static let claude = Logger(subsystem: Log.subsystem, category: "claude")
    public static let ui = Logger(subsystem: Log.subsystem, category: "ui")
}
