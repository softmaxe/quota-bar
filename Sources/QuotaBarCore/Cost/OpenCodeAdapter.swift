import Darwin
import Foundation
import SQLite3

/// Turns OpenCode's database into observed requests. OpenCode keeps every session in one SQLite
/// database it owns, so the database is read whole, on its own read-only connection, whenever its
/// files change.
package struct OpenCodeAdapter: SnapshotAdapter {
    /// Identity of the database and its write-ahead log at the moment they were examined.
    package struct Stamp: Hashable {
        fileprivate let files: [FileStamp?]
    }

    fileprivate struct FileStamp: Hashable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Double
        let changed: Double
    }

    private struct FastToggle {
        let created: Double
        let isFast: Bool
    }

    package var source: CostUsageSource { .openCode }
    private let env: [String: String]
    private let dataDirectory: URL

    package init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        self.dataDirectory = Self.dataDirectory(env: env)
    }

    private var databaseURL: URL { self.dataDirectory.appendingPathComponent("opencode.db") }

    package func survey() -> SnapshotSurvey<Stamp> {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else { return .absent }
        let eligibility = ExternalAgentEligibility.signIn(
            authFile: self.dataDirectory.appendingPathComponent("auth.json"),
            entry: "openai",
            env: self.env
        )
        guard let (included, status) = eligibility.resolved else { return .failed(reason: "auth") }
        return .present(stamp: self.stamp(), included: included, status: status)
    }

    package func requests() throws -> [ObservedRequest] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw SnapshotReadError("database")
        }
        defer { sqlite3_close(db) }

        do {
            try Self.validateSchema(db)
            // One read transaction, so the parts and the Fast toggles come from the same state.
            try Self.exec(db, "BEGIN")
            let requests = try Self.readRequests(db)
            try Self.exec(db, "COMMIT")
            return requests
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw SnapshotReadError("schema")
        }
    }

    /// Nil when either file cannot be examined, so the database is queried regardless.
    private func stamp() -> Stamp? {
        var files: [FileStamp?] = []
        for path in [self.databaseURL.path, self.databaseURL.path + "-wal"] {
            var info = Darwin.stat()
            if fstatat(AT_FDCWD, path, &info, 0) == 0 {
                files.append(FileStamp(
                    device: info.st_dev,
                    inode: info.st_ino,
                    size: info.st_size,
                    modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                    changed: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
                ))
            } else if errno == ENOENT {
                files.append(nil)
            } else {
                return nil
            }
        }
        return Stamp(files: files)
    }

    private static func dataDirectory(env: [String: String]) -> URL {
        if let explicit = env["OPENCODE_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        let home = env["HOME"].flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    private static func validateSchema(_ db: OpaquePointer) throws {
        for table in ["part", "message"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw ScanError.schema
            }
            var columns = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                columns.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            let required: Set<String> = table == "part" ? ["id", "message_id", "data"] : ["id", "data"]
            guard required.isSubset(of: columns) else { throw ScanError.schema }
        }
    }

    private static func readRequests(_ db: OpaquePointer) throws -> [ObservedRequest] {
        // Native OpenAI responses can leave the effective tier in part metadata. The
        // opencodex-fast plugin injects the request after that metadata is built, so its ignored
        // ON/OFF messages are the only durable state signal and act as a fallback.
        let fastToggles = try self.readFastToggles(db)
        let sql = """
        SELECT p.id,
               json_extract(m.data, '$.time.created'),
               json_extract(m.data, '$.modelID'),
               json_extract(p.data, '$.tokens.input'),
               json_extract(p.data, '$.tokens.output'),
               json_extract(p.data, '$.tokens.reasoning'),
               json_extract(p.data, '$.tokens.cache.read'),
               json_extract(p.data, '$.tokens.cache.write'),
               COALESCE(
                   json_extract(m.data, '$.serviceTier'),
                   json_extract(m.data, '$.service_tier'),
                   (
                       SELECT COALESCE(
                           json_extract(mp.data, '$.metadata.openai.serviceTier'),
                           json_extract(mp.data, '$.metadata.openai.service_tier')
                       )
                       FROM part mp
                       WHERE mp.message_id = m.id
                         AND COALESCE(
                             json_extract(mp.data, '$.metadata.openai.serviceTier'),
                             json_extract(mp.data, '$.metadata.openai.service_tier')
                         ) IS NOT NULL
                       ORDER BY mp.id DESC
                       LIMIT 1
                   )
               )
        FROM part p
        JOIN message m ON m.id = p.message_id
        WHERE json_extract(p.data, '$.type') = 'step-finish'
          AND json_extract(m.data, '$.providerID') = 'openai'
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ScanError.schema }
        var requests: [ObservedRequest] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(stmt, 0),
                  let modelText = sqlite3_column_text(stmt, 2) else { continue }
            let input = max(0, Int(sqlite3_column_int64(stmt, 3)))
            let output = max(0, Int(sqlite3_column_int64(stmt, 4)))
                + max(0, Int(sqlite3_column_int64(stmt, 5)))
            let cacheRead = max(0, Int(sqlite3_column_int64(stmt, 6)))
            let cacheWrite = max(0, Int(sqlite3_column_int64(stmt, 7)))
            let totals = TokenTotals(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
            guard totals.total > 0 else { continue }
            let rawTime = sqlite3_column_double(stmt, 1)
            let seconds = rawTime > 10_000_000_000 ? rawTime / 1000 : rawTime
            guard seconds > 0 else { continue }
            let explicitTier = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            requests.append(ObservedRequest(
                key: String(cString: keyText),
                timestamp: Date(timeIntervalSince1970: seconds),
                model: String(cString: modelText),
                tokens: totals,
                isFast: explicitTier.map { CostPricing.CodexServiceTier.parse($0).isFast }
                    ?? self.fastMode(at: rawTime, toggles: fastToggles)
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw ScanError.read }
        return requests
    }

    private static func readFastToggles(_ db: OpaquePointer) throws -> [FastToggle] {
        let sql = """
        SELECT json_extract(m.data, '$.time.created'), json_extract(p.data, '$.text')
        FROM message m
        JOIN part p ON p.message_id = m.id
        WHERE json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
          AND json_extract(p.data, '$.ignored') = 1
          AND json_extract(p.data, '$.text') IN ('Fast mode is now ON.', 'Fast mode is now OFF.')
        ORDER BY 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ScanError.schema }
        var toggles: [FastToggle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 1) else { continue }
            toggles.append(FastToggle(
                created: sqlite3_column_double(stmt, 0),
                isFast: String(cString: text) == "Fast mode is now ON."
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw ScanError.read }
        return toggles
    }

    private static func fastMode(at created: Double, toggles: [FastToggle]) -> Bool {
        var lower = 0
        var upper = toggles.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if toggles[middle].created <= created {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 && toggles[lower - 1].isFast
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ScanError.read }
    }

    private enum ScanError: Error { case schema, read }
}
