import Foundation
import SQLite3

/// Reads recorded tokens without scanning logs, changing schema, or applying rates. Daily and
/// report rows come grouped under the model ID the read's rate card resolves each recorded name
/// to. Each instance uses one SQLite connection and must be used serially.
package final class RecordedUsageReader {
    package struct ModelTier: Hashable {
        package let source: CostUsageSource
        /// The model ID the read's rate card resolves the recorded name to.
        package let model: String
        package let longContext: Bool
        package let isFast: Bool
    }

    package struct DayUsage {
        package let day: String
        package let tier: ModelTier
        package let tokens: TokenTotals
    }

    struct SourceTable {
        let source: CostUsageSource
        let table: String
        let supportsFast: Bool
        let includedOnly: Bool

        var provider: Provider { self.source.provider }

        var requiredColumns: Set<String> {
            var columns = Set(["day", "model", "long_context"] + RecordedUsageReader.tokenColumns)
            if self.supportsFast { columns.insert("is_fast") }
            if self.includedOnly { columns.insert("included") }
            return columns
        }
    }

    static let sourceTables: [SourceTable] = [
        SourceTable(source: .codex, table: "codex_day", supportsFast: true, includedOnly: false),
        SourceTable(source: .claude, table: "claude_message", supportsFast: true, includedOnly: false),
        SourceTable(source: .openCode, table: "opencode_part", supportsFast: true, includedOnly: true),
        SourceTable(source: .piAgent, table: "pi_message", supportsFast: false, includedOnly: true),
    ]

    package static let reportMaximumSafeInteger: Int64 = 9_007_199_254_740_991
    private static let tokenColumns = ["input", "output", "cache_write", "cache_write_1h", "cache_read"]
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
        fromDay: String,
        rateCard: RateCard
    ) throws -> [String: [ModelTier: TokenTotals]] {
        let rows = try self.readDailyUsage(
            tables: Self.sourceTables.filter { $0.provider == provider },
            fromDay: fromDay,
            throughDay: nil,
            rateCard: rateCard,
            validateForReport: false
        )
        var days: [String: [ModelTier: TokenTotals]] = [:]
        for row in rows {
            days[row.day, default: [:]][row.tier, default: TokenTotals()] += row.tokens
        }
        return days
    }

    /// Export tolerates absent source tables, validates safe integers, and bounds both ends.
    /// Schema discovery pins the same committed snapshot used by every source query.
    package func reportUsage(
        fromDay: String,
        throughDay: String,
        rateCard: RateCard,
        afterSchemaDiscovery: (() throws -> Void)? = nil
    ) throws -> [DayUsage] {
        try self.query("BEGIN TRANSACTION") { _ in }
        var transactionOpen = true
        defer {
            if transactionOpen { try? self.query("ROLLBACK") { _ in } }
        }
        let tables = try self.supportedTables()
        // A synchronous observation point lets real writer tests commit between schema and rows.
        try afterSchemaDiscovery?()
        let rows = try self.readDailyUsage(
            tables: tables,
            fromDay: fromDay,
            throughDay: throughDay,
            rateCard: rateCard,
            validateForReport: true
        )
        try self.query("COMMIT") { _ in }
        transactionOpen = false
        return rows
    }

    private func supportedTables() throws -> [SourceTable] {
        var objects: [String: String] = [:]
        let placeholders = Self.sourceTables.map { _ in "?" }.joined(separator: ", ")
        try self.query(
            "SELECT name, type FROM sqlite_master WHERE name IN (\(placeholders))",
            bindings: Self.sourceTables.map(\.table)
        ) { statement in
            guard let name = self.text(statement, column: 0, strict: true),
                  let type = self.text(statement, column: 1, strict: true) else {
                throw RecordedUsageReaderError.corruptSchema("usage object has no name or type")
            }
            objects[name] = type
        }
        var tables: [SourceTable] = []
        for source in Self.sourceTables {
            guard let type = objects[source.table] else { continue }
            guard type == "table" else {
                throw RecordedUsageReaderError.corruptSchema("\(source.table) is a \(type), not a table")
            }
            var columns: Set<String> = []
            try self.query("PRAGMA table_info(\(source.table))") { statement in
                if let name = self.text(statement, column: 1, strict: true) { columns.insert(name) }
            }
            let missing = source.requiredColumns.subtracting(columns).sorted()
            guard missing.isEmpty else {
                throw RecordedUsageReaderError.corruptSchema(
                    "\(source.table) is missing columns: \(missing.joined(separator: ", "))"
                )
            }
            tables.append(source)
        }
        return tables
    }

    private func readDailyUsage(
        tables: [SourceTable],
        fromDay: String,
        throughDay: String?,
        rateCard: RateCard,
        validateForReport: Bool
    ) throws -> [DayUsage] {
        var rows: [DayUsage] = []
        let sums = Self.tokenColumns.map { "SUM(\($0))" }.joined(separator: ", ")
        let validation = validateForReport ? ", MAX(CASE WHEN \(Self.invalidReportTokens) THEN 1 ELSE 0 END)" : ""
        for source in tables {
            let fast = source.supportsFast ? "is_fast" : "FALSE"
            let bounds = throughDay == nil ? "day >= ?" : "day BETWEEN ? AND ?"
            let bindings = [fromDay] + (throughDay.map { [$0] } ?? [])
            try self.query("""
                SELECT day, model, long_context, \(fast), \(sums)\(validation)
                FROM \(source.table)
                WHERE \(source.includedOnly ? "included = 1 AND " : "")\(bounds)
                GROUP BY day, model, long_context, \(fast)
                """, bindings: bindings) { statement in
                guard let day = self.text(statement, column: 0, strict: validateForReport),
                      let model = self.text(statement, column: 1, strict: validateForReport) else {
                    throw RecordedUsageReaderError.invalidData("day or model is NULL or not text")
                }
                if validateForReport, sqlite3_column_int64(statement, 9) != 0 {
                    throw RecordedUsageReaderError.invalidData(
                        "\(source.source.displayName) contains invalid values on \(day)"
                    )
                }
                // Usage is recorded under the name its log reported; it is grouped and priced
                // under the model ID this rate card resolves that name to, so an alias a later
                // price book adds prices usage recorded before it.
                let tier = ModelTier(
                    source: source.source,
                    model: rateCard.modelID(recordedAs: model, provider: source.provider),
                    longContext: sqlite3_column_int64(statement, 2) != 0,
                    isFast: sqlite3_column_int64(statement, 3) != 0
                )
                rows.append(DayUsage(day: day, tier: tier,
                                     tokens: try self.tokens(statement, validateForReport: validateForReport)))
            }
        }
        return rows
    }

    private static var invalidReportTokens: String {
        let fields = Self.tokenColumns.map { column in
            "typeof(\(column)) != 'integer' OR \(column) < 0 OR \(column) > \(Self.reportMaximumSafeInteger)"
        }
        return (fields + ["cache_write_1h > cache_write"]).joined(separator: " OR ")
    }

    private func tokens(_ statement: OpaquePointer, validateForReport: Bool) throws -> TokenTotals {
        let values = try Self.tokenColumns.enumerated().map { offset, name -> Int in
            let column = Int32(offset + 4)
            let value = sqlite3_column_int64(statement, column)
            if validateForReport {
                guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
                    throw RecordedUsageReaderError.invalidData("aggregated \(name) is not an integer")
                }
                guard value >= 0, value <= Self.reportMaximumSafeInteger else {
                    throw RecordedUsageReaderError.invalidData("aggregated \(name) is outside the safe integer range")
                }
            }
            return Int(value)
        }
        // Validate before TokenTotals normalizes the one-hour subset.
        if validateForReport, values[3] > values[2] {
            throw RecordedUsageReaderError.invalidData("aggregated cacheWrite1h exceeds cacheWrite")
        }
        return TokenTotals(input: values[0], output: values[1], cacheWrite: values[2],
                           cacheWrite1h: values[3], cacheRead: values[4])
    }

    private func text(_ statement: OpaquePointer, column: Int32, strict: Bool) -> String? {
        if strict, sqlite3_column_type(statement, column) != SQLITE_TEXT { return nil }
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    /// Pricing counts every recorded day and requires all of the provider's source tables.
    /// Keep SQLite's existing numeric behavior, including promotion in the row expression.
    package func modelUsage(provider: Provider) throws -> [ModelUsageTotal] {
        var totals: [String: Int] = [:]
        for source in Self.sourceTables where source.provider == provider {
            try self.query("""
                SELECT model, SUM(input + output + cache_write + cache_read) AS tokens
                FROM \(source.table)
                \(source.includedOnly ? "WHERE included = 1" : "")
                GROUP BY model
                ORDER BY tokens DESC
                """) { statement in
                guard let model = sqlite3_column_text(statement, 0) else {
                    throw RecordedUsageReaderError.invalidData("model is NULL")
                }
                totals[String(cString: model), default: 0] += Int(sqlite3_column_int64(statement, 1))
            }
        }
        return totals.map { ModelUsageTotal(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
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
    case corruptSchema(String)
    case queryFailed(String)
    case invalidData(String)

    package var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open recorded usage: \(message)"
        case let .corruptSchema(message): "Recorded usage schema is incomplete or corrupt: \(message)"
        case let .queryFailed(message): "Recorded usage query failed: \(message)"
        case let .invalidData(message): "Recorded usage is invalid: \(message)"
        }
    }
}
