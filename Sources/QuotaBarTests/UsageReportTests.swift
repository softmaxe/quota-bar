import Foundation
import QuotaBarCore
import SQLite3

enum UsageReportTests {
    static func run() {
        self.check("usage report aggregates the supported sources") {
            try self.aggregatesSupportedSources()
        }
        self.check("usage report distinguishes empty and recorded zero days") {
            try self.handlesEmptyAndZeroUsage()
        }
        self.check("usage report rejects missing and corrupt databases") {
            try self.rejectsMissingAndCorruptDatabases()
        }
        self.check("usage report validates bounded numeric data") {
            try self.validatesInputsAndNumbers()
        }
    }

    private static func aggregatesSupportedSources() throws {
        try self.withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("usage.sqlite")
            let riskyModel = "x</script><script>alert('report')</script>"
            try self.withDatabase(at: databaseURL) { database in
                try self.execute(self.completeSchema, on: database)
                try self.execute("""
                    INSERT INTO codex_day VALUES
                      ('private-path-a', '2026-09-14', 'codex/model', 0, 0, 10, 2, 4, 1, 3, 1.0, 0),
                      ('private-path-b', '2026-09-14', 'codex/model', 1, 1, 20, 3, 6, 2, 4, 2.0, 1),
                      ('old', '2026-09-12', 'old-model', 0, 0, 1000, 0, 0, 0, 0, 100.0, 0),
                      ('future', '2026-09-16', 'future-model', 0, 0, 1000, 0, 0, 0, 0, 100.0, 0);

                    INSERT INTO claude_message VALUES
                      ('secret-key-a', 'private-path-c', '2026-09-14', 'claude/model', 0, 7, 1, 2, 2, 5, NULL, 0),
                      ('secret-key-b', 'private-path-d', '2026-09-15', 'claude/model', 1, 4, 0, 0, 0, 1, 9.0, NULL);

                    INSERT INTO opencode_part VALUES
                      ('part-a', 1, 0, '2026-09-15', '\(self.sql(riskyModel))', 1, 1, 8, 2, 1, 1, 3, 0.5, 0),
                      ('part-b', 0, 0, '2026-09-15', 'excluded-model', 0, 0, 5000, 0, 0, 0, 0, 50.0, 0);

                    INSERT INTO pi_message VALUES
                      ('message-a', 1, '2026-09-15', 'pi-zero', 0, 0, 0, 0, 0, 0, 0.0, 0),
                      ('message-b', 0, '2026-09-15', 'excluded-pi', 0, 9000, 0, 0, 0, 0, 90.0, 0);
                    """, on: database)
            }

            let report = try UsageReportReader.read(
                databaseURL: databaseURL,
                windowDays: 3,
                now: self.captureDate,
                calendar: self.calendar
            )

            Harness.expectEqual(report.period, "2026-09-13 至 2026-09-15", "report period")
            Harness.expectEqual(report.capturedAt, "2026-09-15T04:34:56.789Z", "capture timestamp")
            Harness.expectEqual(report.timezone, "Asia/Shanghai", "report timezone")
            Harness.expect(report.hasRecordedUsage, "report has recorded usage")
            Harness.expectEqual(
                report.totals,
                UsageReportTotals(
                    input: 49,
                    output: 8,
                    cacheRead: 16,
                    cacheWrite: 13,
                    cacheWrite1h: 6,
                    cost: 3.5,
                    unpricedTokens: 21,
                    total: 86
                ),
                "all-source totals"
            )
            Harness.expectEqual(report.days.map(\.day), ["2026-09-13", "2026-09-14", "2026-09-15"], "day order")
            Harness.expect(!report.days[0].recorded, "missing day is not recorded")
            Harness.expectEqual(report.days[0].total, 0, "missing day is zero-filled")
            Harness.expectEqual(report.days[1].total, 67, "first recorded day total")
            Harness.expectEqual(report.days[1].unpricedTokens, 16, "NULL cost marks full row unpriced")
            Harness.expectEqual(report.days[2].total, 19, "future rows are excluded")
            Harness.expectEqual(report.days[2].unpricedTokens, 5, "NULL unpriced count marks full row unpriced")
            Harness.expectEqual(report.days[2].cost, 0.5, "invalid frozen cost is excluded")

            Harness.expectEqual(report.models.first?.name, "codex/model", "models rank by frozen cost")
            Harness.expectEqual(report.models.first?.total, 52, "long-context and fast tiers combine by model")
            Harness.expectEqual(report.models.first?.cacheWrite1h, 3, "one-hour cache writes sum as a subset")
            Harness.expect(report.models.contains(where: { $0.name == riskyModel }), "HTML-risk model name remains intact")
            Harness.expect(!report.models.contains(where: { $0.name == "excluded-model" }), "excluded OpenCode row stays out")
            Harness.expect(!report.models.contains(where: { $0.name == "excluded-pi" }), "excluded Pi row stays out")
            Harness.expectEqual(report.weekdays.map(\.total), [67, 19, 0, 0, 0, 0, 0], "weekday totals")

            let data = try JSONEncoder().encode(report)
            let encoded = String(decoding: data, as: UTF8.self)
            Harness.expect(!encoded.contains("private-path"), "snapshot omits source paths")
            Harness.expect(!encoded.contains("secret-key"), "snapshot omits record identifiers")
            let decoded = try JSONDecoder().decode(UsageReportSnapshot.self, from: data)
            Harness.expectEqual(decoded, report, "snapshot JSON round trip")
        }
    }

    private static func handlesEmptyAndZeroUsage() throws {
        try self.withTemporaryDirectory { directory in
            let emptyURL = directory.appendingPathComponent("empty.sqlite")
            try self.withDatabase(at: emptyURL) { _ in }
            let empty = try UsageReportReader.read(
                databaseURL: emptyURL,
                windowDays: 1,
                now: self.captureDate,
                calendar: self.calendar
            )
            Harness.expectEqual(empty.totals, UsageReportTotals(), "empty database totals")
            Harness.expectEqual(empty.days.count, 1, "requested one-day window")
            Harness.expect(!empty.days[0].recorded, "empty database has no recorded day")
            Harness.expect(!empty.hasRecordedUsage, "empty database has no usage")
            Harness.expect(empty.models.isEmpty, "empty database has no models")
            Harness.expect(empty.sources.isEmpty, "empty database has no sources")

            let zeroURL = directory.appendingPathComponent("zero.sqlite")
            try self.withDatabase(at: zeroURL) { database in
                try self.execute(self.piSchema, on: database)
                try self.execute("""
                    INSERT INTO pi_message VALUES
                      ('zero', 1, '2026-09-15', 'zero-model', 0, 0, 0, 0, 0, 0, 0.0, 0)
                    """, on: database)
            }
            let zero = try UsageReportReader.read(
                databaseURL: zeroURL,
                windowDays: 1,
                now: self.captureDate,
                calendar: self.calendar
            )
            Harness.expectEqual(zero.totals, UsageReportTotals(), "recorded zero totals")
            Harness.expect(zero.days[0].recorded, "zero-valued row is recorded")
            Harness.expect(zero.hasRecordedUsage, "recorded zero counts as usage history")
            Harness.expectEqual(zero.models.map(\.name), ["zero-model"], "zero model remains present")
            Harness.expectEqual(zero.sources.map(\.name), ["Pi Agent"], "optional source table is readable alone")
        }
    }

    private static func rejectsMissingAndCorruptDatabases() throws {
        try self.withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing/nothing.sqlite")
            Harness.expectThrows("missing usage database") {
                _ = try UsageReportReader.read(databaseURL: missing)
            }
            Harness.expect(!FileManager.default.fileExists(atPath: missing.path), "read does not create a missing database")
            Harness.expect(
                !FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path),
                "read does not create a missing database directory"
            )

            let schemaURL = directory.appendingPathComponent("bad-schema.sqlite")
            try self.withDatabase(at: schemaURL) { database in
                try self.execute("CREATE TABLE codex_day (day TEXT)", on: database)
            }
            Harness.expectThrows("incomplete usage schema") {
                _ = try UsageReportReader.read(databaseURL: schemaURL)
            }

            let corruptURL = directory.appendingPathComponent("corrupt.sqlite")
            try Data("this is not sqlite".utf8).write(to: corruptURL)
            Harness.expectThrows("corrupt SQLite file") {
                _ = try UsageReportReader.read(databaseURL: corruptURL)
            }
        }
    }

    private static func validatesInputsAndNumbers() throws {
        Harness.expectThrows("zero-day window") {
            _ = try UsageReportReader.read(databaseURL: URL(fileURLWithPath: "/missing"), windowDays: 0)
        }
        Harness.expectThrows("window above chart limit") {
            _ = try UsageReportReader.read(databaseURL: URL(fileURLWithPath: "/missing"), windowDays: 31)
        }

        try self.withTemporaryDirectory { directory in
            let negativeURL = directory.appendingPathComponent("negative.sqlite")
            try self.withDatabase(at: negativeURL) { database in
                try self.execute(self.codexSchema, on: database)
                try self.execute("""
                    INSERT INTO codex_day VALUES
                      ('path', '2026-09-15', 'bad', 0, 0, -1, 0, 0, 0, 0, 0.0, 0)
                    """, on: database)
            }
            Harness.expectThrows("negative token count") {
                _ = try UsageReportReader.read(
                    databaseURL: negativeURL,
                    windowDays: 1,
                    now: self.captureDate,
                    calendar: self.calendar
                )
            }

            let unsafeURL = directory.appendingPathComponent("unsafe.sqlite")
            try self.withDatabase(at: unsafeURL) { database in
                try self.execute(self.codexSchema, on: database)
                try self.execute("""
                    INSERT INTO codex_day VALUES
                      ('path', '2026-09-15', 'bad', 0, 0, 9007199254740992, 0, 0, 0, 0, 0.0, 0)
                    """, on: database)
            }
            Harness.expectThrows("JavaScript-unsafe token count") {
                _ = try UsageReportReader.read(
                    databaseURL: unsafeURL,
                    windowDays: 1,
                    now: self.captureDate,
                    calendar: self.calendar
                )
            }

            let infiniteURL = directory.appendingPathComponent("infinite.sqlite")
            try self.withDatabase(at: infiniteURL) { database in
                try self.execute(self.codexSchema, on: database)
                try self.execute("""
                    INSERT INTO codex_day VALUES
                      ('path', '2026-09-15', 'bad', 0, 0, 1, 0, 0, 0, 0, 1e999, 0)
                    """, on: database)
            }
            Harness.expectThrows("non-finite frozen cost") {
                _ = try UsageReportReader.read(
                    databaseURL: infiniteURL,
                    windowDays: 1,
                    now: self.captureDate,
                    calendar: self.calendar
                )
            }
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static var captureDate: Date {
        Date(timeIntervalSince1970: 1_789_446_896.789)
    }

    private static var completeSchema: String {
        self.codexSchema + self.claudeSchema + self.openCodeSchema + self.piSchema
    }

    private static let codexSchema = """
        CREATE TABLE codex_day (
            path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, is_fast INTEGER NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            cost_usd REAL, unpriced_tokens INTEGER
        );
        """

    private static let claudeSchema = """
        CREATE TABLE claude_message (
            key TEXT NOT NULL, path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            cost_usd REAL, unpriced_tokens INTEGER
        );
        """

    private static let openCodeSchema = """
        CREATE TABLE opencode_part (
            key TEXT NOT NULL, included INTEGER NOT NULL, legacy_inferred INTEGER NOT NULL,
            day TEXT NOT NULL, model TEXT NOT NULL, long_context INTEGER NOT NULL,
            is_fast INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            cost_usd REAL, unpriced_tokens INTEGER
        );
        """

    private static let piSchema = """
        CREATE TABLE pi_message (
            key TEXT NOT NULL, included INTEGER NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
            cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            cost_usd REAL, unpriced_tokens INTEGER
        );
        """

    private static func check(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Harness.expect(false, "\(label) threw: \(error.localizedDescription)")
        }
    }

    private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-bar-usage-report-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func withDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw TestError.sqlite("Could not create fixture")
        }
        defer { sqlite3_close(database) }
        try body(database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private enum TestError: LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case let .sqlite(message): "SQLite fixture failed: \(message)"
            }
        }
    }
}
