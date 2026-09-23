import Foundation
import SQLite3

public struct UsageReportTotals: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cacheWrite1h: Int = 0,
        cost: Double = 0,
        unpricedTokens: Int = 0,
        total: Int? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cost = cost
        self.unpricedTokens = unpricedTokens
        self.total = total ?? input + output + cacheRead + cacheWrite
    }
}

public struct UsageReportDay: Codable, Sendable, Equatable {
    public let day: String
    public let recorded: Bool
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(day: String, recorded: Bool, totals: UsageReportTotals = UsageReportTotals()) {
        self.day = day
        self.recorded = recorded
        self.input = totals.input
        self.output = totals.output
        self.cacheRead = totals.cacheRead
        self.cacheWrite = totals.cacheWrite
        self.cacheWrite1h = totals.cacheWrite1h
        self.cost = totals.cost
        self.unpricedTokens = totals.unpricedTokens
        self.total = totals.total
    }
}

public struct UsageReportNamedUsage: Codable, Sendable, Equatable {
    public let name: String
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(name: String, totals: UsageReportTotals = UsageReportTotals()) {
        self.name = name
        self.input = totals.input
        self.output = totals.output
        self.cacheRead = totals.cacheRead
        self.cacheWrite = totals.cacheWrite
        self.cacheWrite1h = totals.cacheWrite1h
        self.cost = totals.cost
        self.unpricedTokens = totals.unpricedTokens
        self.total = totals.total
    }
}

public struct UsageReportWeekday: Codable, Sendable, Equatable {
    public let name: String
    public let total: Int

    public init(name: String, total: Int) {
        self.name = name
        self.total = total
    }
}

public struct UsageReportSnapshot: Codable, Sendable, Equatable {
    public let period: String
    public let capturedAt: String
    public let timezone: String
    public let totals: UsageReportTotals
    public let days: [UsageReportDay]
    public let models: [UsageReportNamedUsage]
    public let sources: [UsageReportNamedUsage]
    public let weekdays: [UsageReportWeekday]

    public init(
        period: String,
        capturedAt: String,
        timezone: String,
        totals: UsageReportTotals,
        days: [UsageReportDay],
        models: [UsageReportNamedUsage],
        sources: [UsageReportNamedUsage],
        weekdays: [UsageReportWeekday]
    ) {
        self.period = period
        self.capturedAt = capturedAt
        self.timezone = timezone
        self.totals = totals
        self.days = days
        self.models = models
        self.sources = sources
        self.weekdays = weekdays
    }

    public var hasRecordedUsage: Bool {
        self.days.contains(where: \.recorded)
    }

    public var defaultFilename: String {
        let endDay = self.days.last?.day ?? "usage"
        return "QuotaBar-Usage-\(endDay).html"
    }
}

public enum UsageReportReaderError: LocalizedError, Equatable {
    case invalidWindowDays(Int)
    case databaseMissing(String)
    case openFailed(String)
    case corruptSchema(String)
    case queryFailed(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidWindowDays(days):
            "Usage report window must contain between 1 and 30 days; received \(days)."
        case let .databaseMissing(path):
            "The usage database does not exist at \(path)."
        case let .openFailed(message):
            "Could not open the usage database for reading: \(message)"
        case let .corruptSchema(message):
            "The usage database schema is incomplete or corrupt: \(message)"
        case let .queryFailed(message):
            "Could not read usage report data: \(message)"
        case let .invalidData(message):
            "The usage database contains invalid report data: \(message)"
        }
    }
}

/// Reads recorded usage from the local scan cache without scanning logs or changing schema, and
/// prices it the same way the popover does: each day at the rates the book gives that day, under
/// the user's overrides.
public enum UsageReportReader {
    fileprivate static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    public static func read(
        databaseURL: URL = CostService.defaultDatabaseURL,
        windowDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        overlay: PricingOverlay? = nil,
        book: PriceBook = .bundled
    ) throws -> UsageReportSnapshot {
        guard (1 ... 30).contains(windowDays) else {
            throw UsageReportReaderError.invalidWindowDays(windowDays)
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw UsageReportReaderError.databaseMissing(databaseURL.path)
        }

        let range = try self.dayRange(windowDays: windowDays, now: now, calendar: calendar)
        let database = try ReadOnlyUsageDatabase(url: databaseURL)
        try database.beginTransaction()
        var transactionOpen = true
        defer {
            if transactionOpen { database.rollback() }
        }

        let tables = try database.supportedTables()
        let rows = try database.readRows(
            tables: tables,
            fromDay: range.keys[0],
            throughDay: range.keys[windowDays - 1],
            overlay: overlay,
            book: book
        )
        try database.commit()
        transactionOpen = false

        var total = CheckedUsage()
        var dayTotals: [String: CheckedUsage] = [:]
        var modelTotals: [String: CheckedUsage] = [:]
        var sourceTotals: [String: CheckedUsage] = [:]
        var recordedDays: Set<String> = []
        let validDays = Set(range.keys)

        for row in rows {
            guard validDays.contains(row.day) else {
                throw UsageReportReaderError.invalidData("unexpected day \(row.day)")
            }
            try total.add(row.usage)
            try dayTotals[row.day, default: CheckedUsage()].add(row.usage)
            try modelTotals[row.model, default: CheckedUsage()].add(row.usage)
            try sourceTotals[row.source, default: CheckedUsage()].add(row.usage)
            recordedDays.insert(row.day)
        }

        let totals = try total.snapshot(label: "report total")
        let days = try range.keys.map { key in
            UsageReportDay(
                day: key,
                recorded: recordedDays.contains(key),
                totals: try dayTotals[key, default: CheckedUsage()].snapshot(label: "day \(key)")
            )
        }
        let models = try modelTotals.map { name, usage in
            UsageReportNamedUsage(name: name, totals: try usage.snapshot(label: "model \(name)"))
        }.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name < $1.name
        }
        let sourceOrder = Dictionary(uniqueKeysWithValues: ReportTable.allCases.enumerated().map {
            ($0.element.source, $0.offset)
        })
        let sources = try sourceTotals.map { name, usage in
            UsageReportNamedUsage(name: name, totals: try usage.snapshot(label: "source \(name)"))
        }.sorted {
            let lhsOrder = sourceOrder[$0.name] ?? Int.max
            let rhsOrder = sourceOrder[$1.name] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return $0.name < $1.name
        }

        var weekdayTotals = Array(repeating: CheckedUsage(), count: 7)
        for index in range.keys.indices where recordedDays.contains(range.keys[index]) {
            let weekday = calendar.component(.weekday, from: range.dates[index])
            guard (1 ... 7).contains(weekday) else {
                throw UsageReportReaderError.invalidData("calendar returned invalid weekday \(weekday)")
            }
            try weekdayTotals[weekday - 1].add(dayTotals[range.keys[index], default: CheckedUsage()])
        }
        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let mondayFirst = [2, 3, 4, 5, 6, 7, 1]
        let weekdays = try mondayFirst.map { weekday in
            let usage = try weekdayTotals[weekday - 1].snapshot(label: weekdayNames[weekday - 1])
            return UsageReportWeekday(name: weekdayNames[weekday - 1], total: usage.total)
        }

        return UsageReportSnapshot(
            period: "\(range.keys[0]) 至 \(range.keys[windowDays - 1])",
            capturedAt: self.timestamp(now),
            timezone: calendar.timeZone.identifier,
            totals: totals,
            days: days,
            models: models,
            sources: sources,
            weekdays: weekdays
        )
    }

    private static func dayRange(
        windowDays: Int,
        now: Date,
        calendar: Calendar
    ) throws -> (dates: [Date], keys: [String]) {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw UsageReportReaderError.invalidData("capture date is not finite")
        }
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - windowDays, to: end) else {
            throw UsageReportReaderError.invalidData("could not calculate report date range")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var dates: [Date] = []
        var keys: [String] = []
        for offset in 0 ..< windowDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw UsageReportReaderError.invalidData("could not calculate report day \(offset + 1)")
            }
            dates.append(date)
            keys.append(formatter.string(from: date))
        }
        guard Set(keys).count == windowDays else {
            throw UsageReportReaderError.invalidData("calendar produced duplicate report days")
        }
        return (dates, keys)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct CheckedUsage {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var cost: Double = 0
    var unpricedTokens: Int64 = 0

    mutating func add(_ other: Self) throws {
        self.input = try self.checkedAdd(self.input, other.input, field: "input")
        self.output = try self.checkedAdd(self.output, other.output, field: "output")
        self.cacheRead = try self.checkedAdd(self.cacheRead, other.cacheRead, field: "cacheRead")
        self.cacheWrite = try self.checkedAdd(self.cacheWrite, other.cacheWrite, field: "cacheWrite")
        self.cacheWrite1h = try self.checkedAdd(self.cacheWrite1h, other.cacheWrite1h, field: "cacheWrite1h")
        self.unpricedTokens = try self.checkedAdd(
            self.unpricedTokens,
            other.unpricedTokens,
            field: "unpricedTokens"
        )
        self.cost += other.cost
        guard self.cost.isFinite, self.cost >= 0 else {
            throw UsageReportReaderError.invalidData("cost is negative or not finite")
        }
    }

    func snapshot(label: String) throws -> UsageReportTotals {
        for (field, value) in [
            ("input", self.input),
            ("output", self.output),
            ("cacheRead", self.cacheRead),
            ("cacheWrite", self.cacheWrite),
            ("cacheWrite1h", self.cacheWrite1h),
            ("unpricedTokens", self.unpricedTokens),
        ] where value < 0 || value > UsageReportReader.maximumSafeInteger {
            throw UsageReportReaderError.invalidData("\(label) \(field) is outside the safe integer range")
        }
        guard self.cacheWrite1h <= self.cacheWrite else {
            throw UsageReportReaderError.invalidData("\(label) cacheWrite1h exceeds cacheWrite")
        }
        let subtotal = try self.checkedAdd(self.input, self.output, field: "total")
        let cached = try self.checkedAdd(self.cacheRead, self.cacheWrite, field: "total")
        let total = try self.checkedAdd(subtotal, cached, field: "total")
        guard self.unpricedTokens <= total else {
            throw UsageReportReaderError.invalidData("\(label) unpricedTokens exceeds total")
        }
        guard self.cost.isFinite, self.cost >= 0 else {
            throw UsageReportReaderError.invalidData("\(label) cost is negative or not finite")
        }
        return UsageReportTotals(
            input: Int(self.input),
            output: Int(self.output),
            cacheRead: Int(self.cacheRead),
            cacheWrite: Int(self.cacheWrite),
            cacheWrite1h: Int(self.cacheWrite1h),
            cost: self.cost,
            unpricedTokens: Int(self.unpricedTokens),
            total: Int(total)
        )
    }

    fileprivate func checkedAdd(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0, sum <= UsageReportReader.maximumSafeInteger else {
            throw UsageReportReaderError.invalidData("\(field) total is outside the safe integer range")
        }
        return sum
    }
}

private enum ReportTable: String, CaseIterable {
    case codexDay = "codex_day"
    case claudeMessage = "claude_message"
    case openCodePart = "opencode_part"
    case piMessage = "pi_message"

    var source: String {
        switch self {
        case .codexDay: "Codex"
        case .claudeMessage: "Claude"
        case .openCodePart: "OpenCode"
        case .piMessage: "Pi Agent"
        }
    }

    var supportsFast: Bool {
        self == .codexDay || self == .openCodePart
    }

    /// Whose price list prices the table. The other agents run OpenAI models on Codex accounts.
    var provider: Provider {
        self == .claudeMessage ? .claude : .codex
    }

    var includedOnly: Bool {
        self == .openCodePart || self == .piMessage
    }

    var requiredColumns: Set<String> {
        var columns: Set<String> = [
            "day", "model", "long_context", "input", "output", "cache_write",
            "cache_write_1h", "cache_read",
        ]
        if self.supportsFast { columns.insert("is_fast") }
        if self.includedOnly { columns.insert("included") }
        return columns
    }
}

private struct UsageReportRow {
    let source: String
    let day: String
    let model: String
    let usage: CheckedUsage
}

private final class ReadOnlyUsageDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &self.database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, self.database != nil else {
            let message = self.errorMessage(fallbackCode: result)
            if let database = self.database { sqlite3_close(database) }
            self.database = nil
            throw UsageReportReaderError.openFailed(message)
        }
    }

    deinit {
        if let database = self.database { sqlite3_close(database) }
    }

    func beginTransaction() throws {
        try self.execute("BEGIN TRANSACTION")
    }

    func commit() throws {
        try self.execute("COMMIT")
    }

    func rollback() {
        try? self.execute("ROLLBACK")
    }

    func supportedTables() throws -> [ReportTable] {
        let statement = try self.prepare(
            "SELECT name, type FROM sqlite_master WHERE name IN ('codex_day', 'claude_message', 'opencode_part', 'pi_message')"
        )
        defer { sqlite3_finalize(statement) }
        var objects: [String: String] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = self.text(statement, column: 0), let type = self.text(statement, column: 1) else {
                throw UsageReportReaderError.corruptSchema("usage object has no name or type")
            }
            objects[name] = type
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw self.queryError() }

        var resultTables: [ReportTable] = []
        for table in ReportTable.allCases {
            guard let type = objects[table.rawValue] else { continue }
            guard type == "table" else {
                throw UsageReportReaderError.corruptSchema("\(table.rawValue) is a \(type), not a table")
            }
            let columns = try self.columns(in: table)
            let missing = table.requiredColumns.subtracting(columns).sorted()
            guard missing.isEmpty else {
                throw UsageReportReaderError.corruptSchema(
                    "\(table.rawValue) is missing columns: \(missing.joined(separator: ", "))"
                )
            }
            resultTables.append(table)
        }
        return resultTables
    }

    func readRows(
        tables: [ReportTable],
        fromDay: String,
        throughDay: String,
        overlay: PricingOverlay?,
        book: PriceBook
    ) throws -> [UsageReportRow] {
        guard !tables.isEmpty else { return [] }
        let queries = tables.map { table in
            let fast = table.supportsFast ? "is_fast" : "0"
            let groupFast = table.supportsFast ? ", is_fast" : ""
            let included = table.includedOnly ? "included = 1 AND " : ""
            let invalid = """
                typeof(input) != 'integer' OR input < 0 OR input > \(UsageReportReader.maximumSafeInteger)
                OR typeof(output) != 'integer' OR output < 0 OR output > \(UsageReportReader.maximumSafeInteger)
                OR typeof(cache_read) != 'integer' OR cache_read < 0 OR cache_read > \(UsageReportReader.maximumSafeInteger)
                OR typeof(cache_write) != 'integer' OR cache_write < 0 OR cache_write > \(UsageReportReader.maximumSafeInteger)
                OR typeof(cache_write_1h) != 'integer' OR cache_write_1h < 0
                OR cache_write_1h > cache_write OR cache_write_1h > \(UsageReportReader.maximumSafeInteger)
                """
            return """
                SELECT '\(table.rawValue)', day, model, \(fast), long_context,
                       SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), SUM(cache_write_1h),
                       MAX(CASE WHEN \(invalid) THEN 1 ELSE 0 END)
                FROM \(table.rawValue)
                WHERE \(included)day BETWEEN ? AND ?
                GROUP BY day, model, long_context\(groupFast)
                """
        }
        let statement = try self.prepare(queries.joined(separator: " UNION ALL "))
        defer { sqlite3_finalize(statement) }
        var parameter: Int32 = 1
        for _ in tables {
            sqlite3_bind_text(statement, parameter, fromDay, -1, Self.transient)
            sqlite3_bind_text(statement, parameter + 1, throughDay, -1, Self.transient)
            parameter += 2
        }

        var rows: [UsageReportRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let tableName = self.text(statement, column: 0),
                  let table = ReportTable(rawValue: tableName),
                  let day = self.text(statement, column: 1),
                  let model = self.text(statement, column: 2)
            else {
                throw UsageReportReaderError.invalidData("source, day, or model is NULL")
            }
            guard sqlite3_column_int64(statement, 10) == 0 else {
                throw UsageReportReaderError.invalidData("\(table.source) contains invalid values on \(day)")
            }
            var usage = CheckedUsage(
                input: try self.integer(statement, column: 5, field: "input"),
                output: try self.integer(statement, column: 6, field: "output"),
                cacheRead: try self.integer(statement, column: 7, field: "cacheRead"),
                cacheWrite: try self.integer(statement, column: 8, field: "cacheWrite"),
                cacheWrite1h: try self.integer(statement, column: 9, field: "cacheWrite1h")
            )
            let tokens = TokenTotals(
                input: Int(usage.input),
                output: Int(usage.output),
                cacheWrite: Int(usage.cacheWrite),
                cacheWrite1h: Int(usage.cacheWrite1h),
                cacheRead: Int(usage.cacheRead)
            )
            let pricing = CostPricing.pricing(
                forNormalizedModel: model,
                provider: table.provider,
                day: day,
                overlay: overlay,
                codexServiceTier: sqlite3_column_int64(statement, 3) != 0 ? .fast : .standard,
                book: book
            )
            if let cost = pricing?.cost(for: tokens, longContext: sqlite3_column_int64(statement, 4) != 0) {
                usage.cost = cost
            } else {
                usage.unpricedTokens = Int64(try usage.snapshot(label: "unpriced usage").total)
            }
            _ = try usage.snapshot(label: "\(table.source) \(day) \(model)")
            rows.append(UsageReportRow(source: table.source, day: day, model: model, usage: usage))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw self.queryError() }
        return rows
    }

    private func columns(in table: ReportTable) throws -> Set<String> {
        let statement = try self.prepare("PRAGMA table_info(\(table.rawValue))")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = self.text(statement, column: 1) { columns.insert(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw self.queryError() }
        return columns
    }

    private func integer(_ statement: OpaquePointer?, column: Int32, field: String) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw UsageReportReaderError.invalidData("aggregated \(field) is not an integer")
        }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= UsageReportReader.maximumSafeInteger else {
            throw UsageReportReaderError.invalidData("aggregated \(field) is outside the safe integer range")
        }
        return value
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(self.database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw self.queryError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(self.database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? self.errorMessage(fallbackCode: result)
            sqlite3_free(error)
            throw UsageReportReaderError.queryFailed(message)
        }
    }

    private func queryError() -> UsageReportReaderError {
        .queryFailed(self.errorMessage(fallbackCode: sqlite3_errcode(self.database)))
    }

    private func errorMessage(fallbackCode: Int32) -> String {
        if let database = self.database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return String(cString: sqlite3_errstr(fallbackCode))
    }
}
