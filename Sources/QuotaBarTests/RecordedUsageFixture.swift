import Foundation
import QuotaBarCore
import SQLite3

/// A real usage database shared by reader and consumer tests. The writer stays open so tests
/// can commit changes, hold transactions, and read committed WAL data through production readers.
final class RecordedUsageFixture {
    let directory: URL
    let databaseURL: URL
    let now: Date
    let calendar: Calendar
    private(set) var database: OpaquePointer?

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
            guard sqlite3_open(self.databaseURL.path, &self.database) == SQLITE_OK else {
                throw FixtureError.sqlite("Could not open fixture")
            }
            try self.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            try self.execute(Self.schema)
            if seed { try self.seedUsage() }
        } catch {
            self.close()
            throw error
        }
    }

    deinit { self.close() }

    func close() {
        if let database { sqlite3_close(database) }
        self.database = nil
        try? FileManager.default.removeItem(at: self.directory)
    }

    var environment: [String: String] {
        [
            "CODEX_HOME": self.directory.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": self.directory.appendingPathComponent("claude").path,
            "OPENCODE_DATA_HOME": self.directory.appendingPathComponent("opencode").path,
            "PI_CODING_AGENT_DIR": self.directory.appendingPathComponent("pi").path,
        ]
    }

    func day(_ offset: Int = 0) -> String {
        DayKey.make(from: self.calendar.date(byAdding: .day, value: offset, to: self.now)!, calendar: self.calendar)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(self.database, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw FixtureError.sqlite(error)
        }
    }

    /// Two individually valid integers overflow SQLite's SUM while it steps the query.
    func addOverflow(source: CostUsageSource) throws {
        switch source {
        case .codex:
            try self.execute("""
                INSERT INTO codex_day VALUES
                ('overflow-a', '\(self.day())', 'zz-overflow', 0, 0, \(Int64.max), 0, 0, 0, 0),
                ('overflow-b', '\(self.day())', 'zz-overflow', 0, 0, 1, 0, 0, 0, 0);
                """)
        case .piAgent:
            try self.execute("""
                INSERT INTO pi_message VALUES
                ('overflow-a', 1, '\(self.day())', 'zz-overflow', 0, \(Int64.max), 0, 0, 0, 0),
                ('overflow-b', 1, '\(self.day())', 'zz-overflow', 0, 1, 0, 0, 0, 0);
                """)
        default:
            throw FixtureError.sqlite("Overflow fixture supports Codex and Pi Agent")
        }
    }

    private func seedUsage() throws {
        try self.execute("""
            INSERT INTO codex_day VALUES
            ('codex-a', '\(self.day(-2))', 'priced-model', 0, 0, 10, 2, 4, 1, 3),
            ('codex-b', '\(self.day(-2))', 'priced-model', 0, 0, 5, 1, 2, 1, 1),
            ('codex-standard', '\(self.day())', 'priced-model', 0, 0, 1, 0, 0, 0, 0),
            ('codex-fast', '\(self.day())', 'priced-model', 1, 1, 20, 3, 6, 2, 4),
            ('old', '\(self.day(-31))', 'old-model', 0, 0, 1000, 0, 0, 0, 0),
            ('future', '\(self.day(1))', 'future-model', 0, 0, 1000, 0, 0, 0, 0);
            INSERT INTO claude_message VALUES
            ('claude-a', 'claude-a', '\(self.day(-2))', 'claude-model', 0, 7, 1, 2, 2, 5),
            ('claude-b', 'claude-b', '\(self.day())', 'claude-model', 1, 4, 0, 0, 0, 1);
            INSERT INTO opencode_part VALUES
            ('open-a', 1, 0, '\(self.day())', 'unpriced-model', 1, 1, 8, 2, 1, 1, 3),
            ('open-excluded', 0, 0, '\(self.day())', 'excluded-model', 0, 0, 5000, 0, 0, 0, 0);
            INSERT INTO pi_message VALUES
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

    static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static let schema = """
        CREATE TABLE codex_day (
            path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, is_fast INTEGER NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            PRIMARY KEY (path, day, model, long_context, is_fast)
        );
        CREATE TABLE claude_message (
            key TEXT PRIMARY KEY, path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL
        );
        CREATE TABLE opencode_part (
            key TEXT PRIMARY KEY, included INTEGER NOT NULL, legacy_inferred INTEGER NOT NULL,
            day TEXT NOT NULL, model TEXT NOT NULL, long_context INTEGER NOT NULL,
            is_fast INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL
        );
        CREATE TABLE pi_message (
            key TEXT PRIMARY KEY, included INTEGER NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL
        );
        """

    private enum FixtureError: Error { case sqlite(String) }
}
