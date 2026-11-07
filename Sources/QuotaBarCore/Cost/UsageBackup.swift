import Foundation
import SQLite3

/// What the saved usage amounts to, for showing before it is backed up.
public struct SavedUsageSummary: Sendable, Equatable {
    public static let empty = SavedUsageSummary(records: 0, firstDay: nil, bytes: 0)

    public let records: Int
    /// `yyyy-MM-dd`, or nil with nothing saved.
    public let firstDay: String?
    public let bytes: Int64

    public init(records: Int, firstDay: String?, bytes: Int64) {
        self.records = records
        self.firstDay = firstDay
        self.bytes = bytes
    }
}

/// What importing a backup changed.
public struct UsageImportResult: Sendable, Equatable {
    /// Records this database did not have.
    public let added: Int
    /// Records and Codex rollouts the backup held further along than this database did.
    public let updated: Int

    public init(added: Int, updated: Int) {
        self.added = added
        self.updated = updated
    }
}

public enum UsageBackupError: LocalizedError {
    case unreadable
    case newerVersion

    public var errorDescription: String? {
        switch self {
        case .unreadable: "That file is not a QuotaBar backup, or it is damaged."
        case .newerVersion: "That backup came from a newer version of QuotaBar. Update QuotaBar, then import it."
        }
    }
}

/// The files around a backup. A backup is a QuotaBar usage database, so any copy of one, whatever
/// version wrote it, can be imported. Nothing here touches Recorded usage.
enum UsageBackup {
    /// Every version has had these; the rest are created when the copy is upgraded.
    private static let requiredTables: Set<String> = ["file_cursor", "codex_day", "claude_message"]

    /// Writes beside `destination` and then moves into place, so a failed export leaves an
    /// earlier backup at that path as it was.
    static func publish(to destination: URL, write: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: partial) }
        try write(partial)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    /// Hands `body` a checked private copy of `source`, which is never opened itself: opening a
    /// database can change it. A database copied by hand can have committed rows still in its WAL.
    static func withStagedCopy<Result>(of source: URL, body: (URL) throws -> Result) throws -> Result {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("quotabar-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("backup.sqlite", isDirectory: false)
        try fileManager.copyItem(at: source, to: copy)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if fileManager.fileExists(atPath: wal.path) {
            try fileManager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        try Self.validate(copy)
        return try body(copy)
    }

    private static func validate(_ copy: URL) throws {
        do {
            let reader = try RecordedUsageReader(databaseURL: copy)
            var tables: Set<String> = []
            try reader.query("SELECT name FROM sqlite_master WHERE type = 'table'") { statement in
                if let name = sqlite3_column_text(statement, 0) { tables.insert(String(cString: name)) }
            }
            guard Self.requiredTables.isSubset(of: tables) else { throw UsageBackupError.unreadable }
            try Self.validateCursors(reader)
            try reader.query("PRAGMA quick_check(1)") { statement in
                guard let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok" else {
                    throw UsageBackupError.unreadable
                }
            }
        } catch is RecordedUsageReaderError {
            throw UsageBackupError.unreadable
        }
    }

    /// Run after migration has supplied historical columns, before touching live data or undo.
    static func validateTokens(_ reader: RecordedUsageReader, schema: String) throws {
        for table in ["codex_day", "claude_message", "opencode_part", "pi_message"] {
            try reader.query("""
                SELECT input, output, cache_write, cache_write_1h, cache_read FROM \(schema).\(table)
                """) { statement in
                var counts: [Int] = []
                for column in Int32(0)..<Int32(5) {
                    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER,
                          let count = Int(exactly: sqlite3_column_int64(statement, column)), count >= 0 else {
                        throw UsageBackupError.unreadable
                    }
                    counts.append(count)
                }
                // Check the raw subset before TokenTotals' compatibility initializer clamps it.
                guard counts[3] <= counts[2],
                      TokenTotals(input: counts[0], output: counts[1], cacheWrite: counts[2],
                                  cacheWrite1h: counts[3], cacheRead: counts[4]).hasValidCounts else {
                    throw UsageBackupError.unreadable
                }
            }
        }
    }

    /// Validate before migrations as well: an upgrade can discard obsolete cursor rows.
    /// Older backups have no resume_state column and legitimately reconstruct it from the log.
    static func validateCursors(_ reader: RecordedUsageReader, schema: String = "main") throws {
        var hasResumeState = false
        try reader.query("PRAGMA \(schema).table_info(file_cursor)") { statement in
            if FileCursor.text(statement, column: 1) == "resume_state" { hasResumeState = true }
        }
        try reader.query("""
            SELECT inode, size, offset, prefix_digest, \(hasResumeState ? "resume_state" : "NULL"), path, provider
            FROM \(schema).file_cursor
            """) { statement in
            guard FileCursor.read(statement) != nil,
                  let path = FileCursor.text(statement, column: 5), !path.isEmpty,
                  let provider = FileCursor.text(statement, column: 6), !provider.isEmpty else {
                throw UsageBackupError.unreadable
            }
        }
    }
}
