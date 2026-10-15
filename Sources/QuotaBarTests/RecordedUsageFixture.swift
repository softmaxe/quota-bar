import Foundation
import QuotaBarCore

/// A real usage database shared by reader and consumer tests. The writer stays open so tests
/// can commit changes, hold transactions, and read committed WAL data through production readers.
final class RecordedUsageFixture {
    let directory: URL
    let databaseURL: URL
    let now: Date
    let calendar: Calendar
    /// The fixture's writer connection.
    let database: TestDatabase

    init(
        now: Date = Date(timeIntervalSince1970: 1_789_446_896.789),
        calendar: Calendar = RecordedUsageFixture.shanghaiCalendar,
        seed: Bool = true
    ) throws {
        self.now = now
        self.calendar = calendar
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-bar-recorded-usage-\(UUID().uuidString)", isDirectory: true)
        self.databaseURL = self.directory.appendingPathComponent("usage.sqlite")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        do {
            // The recorder writes the current production schema, then closes before the writer opens.
            _ = try UsageRecorder(databaseURL: self.databaseURL)
            self.database = try TestDatabase(self.databaseURL)
            try self.database.exec("PRAGMA wal_autocheckpoint=0;")
            if seed { try self.seedUsage() }
        } catch {
            try? FileManager.default.removeItem(at: self.directory)
            throw error
        }
    }

    deinit { self.close() }

    func close() {
        self.database.close()
        try? FileManager.default.removeItem(at: self.directory)
    }

    func day(_ offset: Int = 0) -> String {
        DayKey.make(from: self.calendar.date(byAdding: .day, value: offset, to: self.now)!, calendar: self.calendar)
    }

    /// Two individually valid integers overflow SQLite's SUM while it steps the query.
    func addOverflow(source: CostUsageSource) throws {
        switch source {
        case .codex:
            try self.database.exec("""
                INSERT INTO codex_day (\(Self.codexColumns)) VALUES
                ('overflow-a', '\(self.day())', 'zz-overflow', 0, 0, \(Int64.max), 0, 0, 0, 0),
                ('overflow-b', '\(self.day())', 'zz-overflow', 0, 0, 1, 0, 0, 0, 0);
                """)
        case .piAgent:
            try self.database.exec("""
                INSERT INTO pi_message (\(Self.piColumns)) VALUES
                ('overflow-a', 1, '\(self.day())', 'zz-overflow', 0, \(Int64.max), 0, 0, 0, 0),
                ('overflow-b', 1, '\(self.day())', 'zz-overflow', 0, 1, 0, 0, 0, 0);
                """)
        default:
            throw TestDatabaseError.sqlite("Overflow fixture supports Codex and Pi Agent")
        }
    }

    private func seedUsage() throws {
        try self.database.exec("""
            INSERT INTO codex_day (\(Self.codexColumns)) VALUES
            ('codex-a', '\(self.day(-2))', 'priced-model', 0, 0, 10, 2, 4, 1, 3),
            ('codex-b', '\(self.day(-2))', 'priced-model', 0, 0, 5, 1, 2, 1, 1),
            ('codex-standard', '\(self.day())', 'priced-model', 0, 0, 1, 0, 0, 0, 0),
            ('codex-fast', '\(self.day())', 'priced-model', 1, 1, 20, 3, 6, 2, 4),
            ('old', '\(self.day(-31))', 'old-model', 0, 0, 1000, 0, 0, 0, 0),
            ('future', '\(self.day(1))', 'future-model', 0, 0, 1000, 0, 0, 0, 0);
            INSERT INTO claude_message (\(Self.claudeColumns)) VALUES
            ('claude-a', 'claude-a', '\(self.day(-2))', 'claude-model', 0, 0, 7, 1, 2, 2, 5),
            ('claude-b', 'claude-b', '\(self.day())', 'claude-model', 1, 0, 4, 0, 0, 0, 1);
            INSERT INTO opencode_part (\(Self.openCodeColumns)) VALUES
            ('open-a', 1, 0, '\(self.day())', 'unpriced-model', 1, 1, 8, 2, 1, 1, 3),
            ('open-excluded', 0, 0, '\(self.day())', 'excluded-model', 0, 0, 5000, 0, 0, 0, 0);
            INSERT INTO pi_message (\(Self.piColumns)) VALUES
            ('pi-a', 1, '\(self.day())', 'priced-model', 0, 6, 0, 0, 0, 0),
            ('pi-zero', 1, '\(self.day(-3))', 'zero-model', 0, 0, 0, 0, 0, 0),
            ('pi-excluded', 0, '\(self.day())', 'excluded-pi', 0, 9000, 0, 0, 0, 0);
            """)
    }

    /// $1 per Standard token and $2 per Long-context token, with Fast multiplying either by 10.
    /// The stored Long-context row is deliberately below the threshold.
    static func rateCard() throws -> RateCard {
        RateCard(book: try PriceBook(data: Data("""
            { "schemaVersion": 1, "providers": { "codex": {
                "source": "https://example.com", "checkedAt": "2026-09-01",
                "models": [{ "id": "priced-model", "periods": [{
                    "rates": {
                        "input": 1000000, "output": 1000000, "cacheWrite": 1000000,
                        "cacheWrite1h": 1000000, "cacheRead": 1000000, "thresholdTokens": 100,
                        "inputAbove": 2000000, "outputAbove": 2000000, "cacheWriteAbove": 2000000,
                        "cacheWrite1hAbove": 2000000, "cacheReadAbove": 2000000
                    }, "fastMultiplier": 10
                }] }]
            } } }
            """.utf8)))
    }

    // Column lists for INSERTs, so seeded values do not depend on the production column order.
    static let codexColumns =
        "path, day, model, long_context, is_fast, input, output, cache_write, cache_write_1h, cache_read"
    static let claudeColumns =
        "key, path, day, model, long_context, is_fast, input, output, cache_write, cache_write_1h, cache_read"
    static let openCodeColumns = "key, included, legacy_inferred, day, model, long_context, is_fast, "
        + "input, output, cache_write, cache_write_1h, cache_read"
    static let piColumns =
        "key, included, day, model, long_context, input, output, cache_write, cache_write_1h, cache_read"

    static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}
