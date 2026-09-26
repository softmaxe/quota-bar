import Foundation
import SQLite3

/// Reads recorded tokens without scanning logs, changing schema, or applying rates.
/// Each instance uses one SQLite connection and must be used serially.
package final class RecordedUsageReader {
    package struct ModelTier: Hashable {
        package let source: CostUsageSource
        package let model: String
        package let longContext: Bool
        package let isFast: Bool
    }

    struct SourceTable {
        let source: CostUsageSource
        let table: String
        let supportsFast: Bool
        let includedOnly: Bool

        var provider: Provider { self.source == .claude ? .claude : .codex }
    }

    static let sourceTables: [SourceTable] = [
        SourceTable(source: .codex, table: "codex_day", supportsFast: true, includedOnly: false),
        SourceTable(source: .claude, table: "claude_message", supportsFast: false, includedOnly: false),
        SourceTable(source: .openCode, table: "opencode_part", supportsFast: true, includedOnly: true),
        SourceTable(source: .piAgent, table: "pi_message", supportsFast: false, includedOnly: true),
    ]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let database: OpaquePointer?
    private let ownsConnection: Bool

    /// Independent read-only access does not queue behind the scan actor.
    package init(databaseURL: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, database != nil else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let database { sqlite3_close(database) }
            throw RecordedUsageReaderError.openFailed(message)
        }
        self.database = database
        self.ownsConnection = true
    }

    /// The cache owns this connection and must outlive the read.
    init(database: OpaquePointer?) {
        self.database = database
        self.ownsConnection = false
    }

    deinit {
        if self.ownsConnection, let database { sqlite3_close(database) }
    }

    /// The menu requires all of its provider's tables and has no upper date bound.
    /// SQLite's integer decoding remains unchanged; report-specific validation is separate.
    package func dailyUsage(
        provider: Provider,
        fromDay: String
    ) throws -> [String: [ModelTier: TokenTotals]] {
        var days: [String: [ModelTier: TokenTotals]] = [:]
        for source in Self.sourceTables where source.provider == provider {
            let fast = source.supportsFast ? "is_fast" : "FALSE"
            try self.query("""
                SELECT day, model, long_context, \(fast),
                       SUM(input), SUM(output), SUM(cache_write), SUM(cache_write_1h), SUM(cache_read)
                FROM \(source.table)
                WHERE \(source.includedOnly ? "included = 1 AND " : "")day >= ?
                GROUP BY day, model, long_context, \(fast)
                """, bindings: [fromDay]) { statement in
                guard let day = sqlite3_column_text(statement, 0),
                      let model = sqlite3_column_text(statement, 1) else {
                    throw RecordedUsageReaderError.invalidData("day or model is NULL")
                }
                let tier = ModelTier(
                    source: source.source,
                    model: String(cString: model),
                    longContext: sqlite3_column_int64(statement, 2) != 0,
                    isFast: sqlite3_column_int64(statement, 3) != 0
                )
                days[String(cString: day), default: [:]][tier, default: TokenTotals()] += TokenTotals(
                    input: Int(sqlite3_column_int64(statement, 4)),
                    output: Int(sqlite3_column_int64(statement, 5)),
                    cacheWrite: Int(sqlite3_column_int64(statement, 6)),
                    cacheWrite1h: Int(sqlite3_column_int64(statement, 7)),
                    cacheRead: Int(sqlite3_column_int64(statement, 8))
                )
            }
        }
        return days
    }

    /// Results stay local to the read until every contributing statement completes.
    func query(
        _ sql: String,
        bindings: [String] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(self.database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { throw self.queryError() }
        for (offset, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, Self.transient) == SQLITE_OK else {
                throw self.queryError()
            }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try row(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw self.queryError() }
    }

    private func queryError() -> RecordedUsageReaderError {
        .queryFailed(String(cString: sqlite3_errmsg(self.database)))
    }
}

package enum RecordedUsageReaderError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case invalidData(String)

    package var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open recorded usage: \(message)"
        case let .queryFailed(message): "Recorded usage query failed: \(message)"
        case let .invalidData(message): "Recorded usage is invalid: \(message)"
        }
    }
}
