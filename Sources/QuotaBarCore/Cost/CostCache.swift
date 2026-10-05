// Persistent compact usage store, modelled on CodexBar's opencodex-usage sqlite store
// (MIT, © 2026 Peter Steinberger).
//
// Rescanning ~750MB of JSONL on every refresh is not viable, so each file's parse position is
// remembered and only the bytes appended since the last scan are read.

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Where a file was left off. A file is resumable only if its identity still matches.
package struct FileCursor {
    /// Zero marks a Codex rollout whose deletion was observed, so a restored copy can resume.
    package let inode: UInt64
    package let size: Int64
    package let offset: Int64
    /// Digest of the first 64KB, so a rewritten-in-place file is detected even at the same size.
    package let prefixDigest: String
    /// Opaque scanner state at `offset`. Only the scanner that wrote it may decode it.
    let resumeStateJSON: String?

    package init(
        inode: UInt64,
        size: Int64,
        offset: Int64,
        prefixDigest: String,
        resumeStateJSON: String? = nil
    ) {
        self.inode = inode
        self.size = size
        self.offset = offset
        self.prefixDigest = prefixDigest
        self.resumeStateJSON = resumeStateJSON
    }
}

final class CostCache {
    private var db: OpaquePointer?
    /// Per-row and per-file statements, compiled once per connection. Scans run them hundreds of
    /// thousands of times, and compiling the upserts cost more than executing them.
    private var statements: [String: OpaquePointer] = [:]

    init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open(path.path, &self.db) == SQLITE_OK else {
            throw CostCacheError.openFailed(self.lastErrorMessage)
        }
        try self.exec("PRAGMA journal_mode=WAL")
        try self.exec("PRAGMA synchronous=NORMAL")
        // Usage is durable history. Schema upgrades must preserve rows whose source is gone.
        try self.createSchema()
    }

    deinit {
        for stmt in self.statements.values { sqlite3_finalize(stmt) }
        if let db = self.db { sqlite3_close(db) }
    }

    private func createSchema() throws {
        try self.exec("""
        CREATE TABLE IF NOT EXISTS file_cursor (
            path TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            prefix_digest TEXT NOT NULL,
            resume_state TEXT
        )
        """)
        try self.addColumnIfMissing(table: "file_cursor", name: "resume_state", definition: "TEXT")
        try self.createCodexDayTable()
        // Added without rebuilding the table. Add it first so the primary-key migration below can
        // copy every historical value with one fixed statement.
        try self.addColumnIfMissing(table: "codex_day", name: "cache_write_1h", definition: "INTEGER NOT NULL DEFAULT 0")
        try self.migrateLegacyCodexDayIfNeeded()
        // Claude replays the same assistant message into several transcripts, so rows are keyed
        // by message identity; a replay updates the row rather than adding to it.
        try self.exec("""
        CREATE TABLE IF NOT EXISTS claude_message (
            key TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            long_context INTEGER NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL,
            cache_read INTEGER NOT NULL
        )
        """)
        try self.exec("CREATE INDEX IF NOT EXISTS claude_message_path ON claude_message(path)")
        try self.exec("CREATE INDEX IF NOT EXISTS claude_message_day ON claude_message(day)")
        try self.exec("CREATE INDEX IF NOT EXISTS codex_day_day ON codex_day(day)")
        try self.exec("""
        CREATE TABLE IF NOT EXISTS opencode_part (
            key TEXT PRIMARY KEY,
            included INTEGER NOT NULL,
            legacy_inferred INTEGER NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            long_context INTEGER NOT NULL,
            is_fast INTEGER NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL
        )
        """)
        try self.addColumnIfMissing(table: "opencode_part", name: "is_fast", definition: "INTEGER NOT NULL DEFAULT 0")
        try self.exec("CREATE INDEX IF NOT EXISTS opencode_part_day ON opencode_part(day)")
        try self.exec("""
        CREATE TABLE IF NOT EXISTS pi_message (
            key TEXT PRIMARY KEY,
            included INTEGER NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            long_context INTEGER NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL
        )
        """)
        try self.exec("CREATE INDEX IF NOT EXISTS pi_message_day ON pi_message(day)")
        try self.exec("""
        CREATE TABLE IF NOT EXISTS opencode_state (
            key TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        )
        """)

        // The one-hour cache-write subset, split out once Anthropic's higher rate for it was
        // applied. Zero for Codex, which offers no choice of cache lifetime.
        try self.addColumnIfMissing(table: "claude_message", name: "cache_write_1h", definition: "INTEGER NOT NULL DEFAULT 0")
        // Claude Fast mode, added when it was first priced. Rows scanned earlier stay Standard,
        // because the transcripts behind them may already be gone.
        try self.addColumnIfMissing(table: "claude_message", name: "is_fast", definition: "INTEGER NOT NULL DEFAULT 0")

        try self.dropStoredCostColumns()
    }

    /// Versions up to 1.0.7 froze each row's cost at scan time. Cost is now derived from the
    /// tokens and the dated price book whenever it is read, so the stored figures, and the
    /// partial indexes that found rows still waiting for one, are dropped. Tokens are untouched.
    private func dropStoredCostColumns() throws {
        let tables = ["claude_message", "codex_day", "opencode_part", "pi_message"]
        var pending: [(table: String, column: String)] = []
        for table in tables {
            for column in ["cost_usd", "unpriced_tokens"] where try self.columnExists(table: table, name: column) {
                pending.append((table, column))
            }
        }
        guard !pending.isEmpty else { return }

        try self.exec("BEGIN IMMEDIATE")
        do {
            for table in tables { try self.exec("DROP INDEX IF EXISTS \(table)_unpriced") }
            for item in pending { try self.exec("ALTER TABLE \(item.table) DROP COLUMN \(item.column)") }
            try self.exec("COMMIT")
        } catch {
            try? self.exec("ROLLBACK")
            throw error
        }
    }

    /// Codex turns carry no message identity, but a turn appears in exactly one rollout file,
    /// so per-file day/model/tier rows are enough.
    private func createCodexDayTable() throws {
        try self.exec("""
        CREATE TABLE IF NOT EXISTS codex_day (
            path TEXT NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            long_context INTEGER NOT NULL,
            is_fast INTEGER NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL,
            PRIMARY KEY (path, day, model, long_context, is_fast)
        )
        """)
    }

    private func migrateLegacyCodexDayIfNeeded() throws {
        guard !(try self.columnExists(table: "codex_day", name: "is_fast")) else { return }

        try self.exec("BEGIN IMMEDIATE")
        do {
            try self.exec("ALTER TABLE codex_day RENAME TO codex_day_legacy")
            try self.createCodexDayTable()
            try self.exec("""
            INSERT INTO codex_day
                (path, day, model, long_context, is_fast, input, output, cache_write,
                 cache_write_1h, cache_read)
            SELECT path, day, model, long_context, 0, input, output, cache_write,
                   cache_write_1h, cache_read
            FROM codex_day_legacy
            """)
            try self.exec("DROP TABLE codex_day_legacy")
            try self.exec("COMMIT")
        } catch {
            try? self.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Cursors

    /// Largest completed scan first, for choosing one retained copy of a session's log.
    func trackedPaths(provider: Provider) throws -> [String] {
        let stmt = try self.prepared(
            "SELECT path FROM file_cursor WHERE provider = ? ORDER BY offset DESC, size DESC, path"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        var paths: [String] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            paths.append(String(cString: sqlite3_column_text(stmt, 0)))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw CostCacheError.statementFailed(self.lastErrorMessage) }
        return paths
    }

    func cursor(forPath path: String) -> FileCursor? {
        let stmt = try? self.reusable(
            "SELECT inode, size, offset, prefix_digest, resume_state FROM file_cursor WHERE path = ?"
        )
        defer { sqlite3_reset(stmt) }
        guard stmt != nil else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return FileCursor(
            inode: UInt64(sqlite3_column_int64(stmt, 0)),
            size: sqlite3_column_int64(stmt, 1),
            offset: sqlite3_column_int64(stmt, 2),
            prefixDigest: String(cString: sqlite3_column_text(stmt, 3)),
            resumeStateJSON: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 4))
        )
    }

    func setCursor(_ cursor: FileCursor, forPath path: String, provider: Provider) throws {
        let stmt = try self.reusable("""
            INSERT OR REPLACE INTO file_cursor
                (path, provider, inode, size, offset, prefix_digest, resume_state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 3, Int64(cursor.inode))
        sqlite3_bind_int64(stmt, 4, cursor.size)
        sqlite3_bind_int64(stmt, 5, cursor.offset)
        sqlite3_bind_text(stmt, 6, cursor.prefixDigest, -1, sqliteTransient)
        if let resumeStateJSON = cursor.resumeStateJSON {
            sqlite3_bind_text(stmt, 7, resumeStateJSON, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        try self.step(stmt)
    }

    /// Drops everything derived from a file, for when it was rewritten rather than appended to.
    func forget(path: String) throws {
        for sql in [
            "DELETE FROM codex_day WHERE path = ?",
            "DELETE FROM claude_message WHERE path = ?",
            "DELETE FROM file_cursor WHERE path = ?",
        ] {
            let stmt = try self.reusable(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
            try self.step(stmt)
        }
    }

    // MARK: - Writes

    func beginTransaction() throws { try self.exec("BEGIN IMMEDIATE") }
    func commit() throws { try self.exec("COMMIT") }
    func rollback() { try? self.exec("ROLLBACK") }

    func addCodexTokens(
        path: String,
        day: String,
        model: String,
        longContext: Bool,
        isFast: Bool,
        totals: TokenTotals
    ) throws {
        let stmt = try self.reusable("""
            INSERT INTO codex_day
                (path, day, model, long_context, is_fast, input, output, cache_write,
                 cache_write_1h, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path, day, model, long_context, is_fast) DO UPDATE SET
                input = input + excluded.input,
                output = output + excluded.output,
                cache_write = cache_write + excluded.cache_write,
                cache_write_1h = cache_write_1h + excluded.cache_write_1h,
                cache_read = cache_read + excluded.cache_read
            """)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, day, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, model, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 4, longContext ? 1 : 0)
        sqlite3_bind_int64(stmt, 5, isFast ? 1 : 0)
        self.bindUsage(stmt, from: 6, totals: totals)
        try self.step(stmt)
    }

    func addClaudeMessage(
        key: String,
        path: String,
        day: String,
        model: String,
        longContext: Bool,
        isFast: Bool,
        totals: TokenTotals
    ) throws {
        let stmt = try self.reusable("""
            INSERT INTO claude_message
                (key, path, day, model, long_context, is_fast, input, output, cache_write,
                 cache_write_1h, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                path = excluded.path,
                day = excluded.day,
                model = excluded.model,
                long_context = excluded.long_context,
                is_fast = excluded.is_fast,
                input = excluded.input,
                output = excluded.output,
                cache_write = excluded.cache_write,
                cache_write_1h = excluded.cache_write_1h,
                cache_read = excluded.cache_read
            -- Streaming writes the same message several times as it completes; only the chunk
            -- that grew the reply supersedes what is already stored. Everything else is a replay
            -- of a message this cache already has, and must not overwrite the finished figure.
            WHERE excluded.output > claude_message.output
            """)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, path, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, day, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, model, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 5, longContext ? 1 : 0)
        sqlite3_bind_int64(stmt, 6, isFast ? 1 : 0)
        self.bindUsage(stmt, from: 7, totals: totals)
        try self.step(stmt)
    }

    func hasCompletedOpenCodeBackfill() throws -> Bool {
        let stmt = try self.prepared("SELECT value FROM opencode_state WHERE key = 'backfill_complete'")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) != 0
    }

    func markOpenCodeBackfillComplete() throws {
        try self.exec("INSERT OR REPLACE INTO opencode_state (key, value) VALUES ('backfill_complete', 1)")
    }

    func addOpenCodePart(
        key: String,
        included: Bool,
        legacyInferred: Bool,
        day: String,
        model: String,
        longContext: Bool,
        isFast: Bool,
        totals: TokenTotals
    ) throws {
        let stmt = try self.reusable("""
            INSERT INTO opencode_part
                (key, included, legacy_inferred, day, model, long_context, is_fast, input,
                 output, cache_write, cache_write_1h, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                day = excluded.day,
                model = excluded.model,
                long_context = excluded.long_context,
                is_fast = excluded.is_fast,
                input = excluded.input,
                output = excluded.output,
                cache_write = excluded.cache_write,
                cache_write_1h = excluded.cache_write_1h,
                cache_read = excluded.cache_read
            WHERE excluded.day IS NOT opencode_part.day
               OR excluded.model IS NOT opencode_part.model
               OR excluded.is_fast IS NOT opencode_part.is_fast
               OR excluded.input IS NOT opencode_part.input
               OR excluded.output IS NOT opencode_part.output
               OR excluded.cache_write IS NOT opencode_part.cache_write
               OR excluded.cache_write_1h IS NOT opencode_part.cache_write_1h
               OR excluded.cache_read IS NOT opencode_part.cache_read
            """)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 2, included ? 1 : 0)
        sqlite3_bind_int64(stmt, 3, legacyInferred ? 1 : 0)
        sqlite3_bind_text(stmt, 4, day, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 5, model, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 6, longContext ? 1 : 0)
        sqlite3_bind_int64(stmt, 7, isFast ? 1 : 0)
        self.bindUsage(stmt, from: 8, totals: totals)
        try self.step(stmt)
    }

    func addPiMessage(
        key: String,
        included: Bool,
        day: String,
        model: String,
        longContext: Bool,
        totals: TokenTotals
    ) throws {
        let stmt = try self.reusable("""
            INSERT INTO pi_message
                (key, included, day, model, long_context, input, output, cache_write,
                 cache_write_1h, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                day = excluded.day, model = excluded.model, long_context = excluded.long_context,
                input = excluded.input, output = excluded.output,
                cache_write = excluded.cache_write, cache_write_1h = excluded.cache_write_1h,
                cache_read = excluded.cache_read
            WHERE excluded.day IS NOT pi_message.day
               OR excluded.model IS NOT pi_message.model
               OR excluded.input IS NOT pi_message.input
               OR excluded.output IS NOT pi_message.output
               OR excluded.cache_write IS NOT pi_message.cache_write
               OR excluded.cache_write_1h IS NOT pi_message.cache_write_1h
               OR excluded.cache_read IS NOT pi_message.cache_read
            """)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 2, included ? 1 : 0)
        sqlite3_bind_text(stmt, 3, day, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, model, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 5, longContext ? 1 : 0)
        self.bindUsage(stmt, from: 6, totals: totals)
        try self.step(stmt)
    }

    // MARK: - Reads

    /// Borrows the writer connection after its scan has finished.
    var recordedUsageReader: RecordedUsageReader { RecordedUsageReader(database: self.db) }

    // MARK: - Helpers

    /// A statement kept for the life of the connection, bound fresh. The caller resets it after
    /// stepping, which releases its read of the database, and never finalizes it.
    private func reusable(_ sql: String) throws -> OpaquePointer? {
        if let stmt = self.statements[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(self.db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK,
              let stmt else {
            sqlite3_finalize(stmt)
            throw CostCacheError.statementFailed(self.lastErrorMessage)
        }
        self.statements[sql] = stmt
        return stmt
    }

    /// Prepares one statement or throws with SQLite's own message. The caller finalizes it.
    private func prepared(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw CostCacheError.statementFailed(self.lastErrorMessage)
        }
        return stmt
    }

    /// The five token columns every usage row ends with, bound from `index`.
    private func bindUsage(_ stmt: OpaquePointer?, from index: Int32, totals: TokenTotals) {
        sqlite3_bind_int64(stmt, index, Int64(totals.input))
        sqlite3_bind_int64(stmt, index + 1, Int64(totals.output))
        sqlite3_bind_int64(stmt, index + 2, Int64(totals.cacheWrite))
        sqlite3_bind_int64(stmt, index + 3, Int64(totals.cacheWrite1h))
        sqlite3_bind_int64(stmt, index + 4, Int64(totals.cacheRead))
    }

    /// Runs a statement expected to produce no rows.
    private func step(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CostCacheError.statementFailed(self.lastErrorMessage)
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(self.db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw CostCacheError.statementFailed(message)
        }
    }

    private func addColumnIfMissing(table: String, name: String, definition: String) throws {
        guard !(try self.columnExists(table: table, name: name)) else { return }
        try self.exec("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private func columnExists(table: String, name: String) throws -> Bool {
        let stmt = try self.prepared("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == name { return true }
        }
        return false
    }

    private var lastErrorMessage: String {
        guard let db = self.db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }
}

enum CostCacheError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open the usage cache: \(message)"
        case let .statementFailed(message): "Usage cache query failed: \(message)"
        }
    }
}
