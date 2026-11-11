import Foundation
import QuotaBarCore

enum UsageReportTests {
    static func run() {
        self.check("non-Gregorian calendars record queryable days at the correct price period") {
            try self.gregorianRecordingAndPricing()
        }
        self.check("usage report aggregates the supported sources") {
            try self.aggregatesSupportedSources()
        }
        self.check("usage report prices each day at its own period") {
            try self.pricesEachDayAtItsPeriod()
        }
        self.check("usage report distinguishes empty and recorded zero days") {
            try self.handlesEmptyAndZeroUsage()
        }
        self.check("usage report rejects missing and corrupt databases") {
            try self.rejectsMissingAndCorruptDatabases()
        }
        self.check("usage report rejects windows outside the chart range") {
            self.rejectsInvalidWindows()
        }
        self.check("usage report keeps committed WAL data visible and uncommitted writes invisible") {
            try self.readsCommittedWAL()
        }
        self.check("usage report uses one snapshot for schema and all source rows") {
            try self.keepsSchemaAndRowsInOneSnapshot()
        }
        self.check("usage report preserves raw and aggregate validation") {
            try self.validatesRawAndAggregatedTokens()
        }
        self.check("usage report propagates execution failure after earlier source rows") {
            try self.rejectsPartialReads()
        }
    }

    private static func gregorianRecordingAndPricing() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let fixture = try RecordedUsageFixture(now: ISO8601.parse("2026-11-10T16:00:00Z")!,
                                               calendar: calendar, seed: false)
        try fixture.database.exec("""
            INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns)) VALUES
              ('before', '\(fixture.day(-1))', 'dated-model', 0, 0, 1000000, 0, 0, 0, 0),
              ('after', '\(fixture.day())', 'dated-model', 0, 0, 1000000, 0, 0, 0, 0);
            """)
        let book = try PriceBook(data: Data("""
            { "schemaVersion": 1, "providers": { "codex": {
                "source": "https://example.com", "checkedAt": "2026-11-11",
                "models": [{ "id": "dated-model", "periods": [
                    { "rates": { "input": 1, "output": 1 } },
                    { "from": "2026-11-11", "rates": { "input": 2, "output": 2 } },
                    { "from": "2026-11-12", "rates": { "input": 3, "output": 3 } }
                ] }]
            } } }
            """.utf8))
        let report = try UsageReportReader.read(databaseURL: fixture.databaseURL, windowDays: 2,
                                                now: fixture.now, calendar: calendar, rateCard: RateCard(book: book))
        Harness.expectEqual(report.days.map(\.day), ["2026-11-10", "2026-11-11"],
                            "report query bounds use Gregorian local days")
        Harness.expectEqual(report.days.map(\.total), [1_000_000, 1_000_000],
                            "records made with a Buddhist calendar remain visible in the report")
        Harness.expectClose(report.days[0].cost, 1, "the day before the local price boundary keeps its rate")
        Harness.expectClose(report.days[1].cost, 2, "the new local day uses its rate, not a future period")
    }

    /// The shared seed over three days: 09-13 holds Codex and Claude rows, 09-14 nothing, and
    /// 09-15 every source, while 09-12, an old row, and a future row fall outside the window.
    private static func aggregatesSupportedSources() throws {
        let fixture = try RecordedUsageFixture()
        // Recorded usage keeps names without a path, so the risk is markup rather than `</script>`.
        let riskyModel = "x\"><img src=x onerror=alert('report')>"
        try fixture.database.exec("""
            INSERT INTO opencode_part (\(RecordedUsageFixture.openCodeColumns)) VALUES
              ('risky', 1, 0, '\(fixture.day())', '\(self.sql(riskyModel))', 0, 0, 0, 0, 0, 0, 0);
            """)
        let report = try UsageReportReader.read(
            databaseURL: fixture.databaseURL,
            windowDays: 3,
            now: fixture.now,
            calendar: self.calendar,
            rateCard: try RecordedUsageFixture.rateCard()
        )

        Harness.expect(report.hasRecordedUsage, "report has recorded usage")
        Harness.expectEqual(report.days.map(\.day), ["2026-09-13", "2026-09-14", "2026-09-15"], "day order")
        let first = report.days[0]
        Harness.expectEqual([first.input, first.output, first.cacheRead, first.cacheWrite, first.cacheWrite1h],
                            [22, 4, 9, 8, 4], "first recorded day token types")
        Harness.expectEqual(first.total, 43, "first recorded day total")
        Harness.expectEqual(report.days[0].unpricedTokens, 15, "a model the book does not list is unpriced")
        Harness.expectClose(report.days[0].cost, 28, "Standard tokens cost $1 each")
        Harness.expect(!report.days[1].recorded, "missing day is not recorded")
        Harness.expectEqual(report.days[1].total, 0, "missing day is zero-filled")
        Harness.expectEqual(report.days[2].total, 9059, "future rows are excluded")
        Harness.expectEqual(report.days[2].unpricedTokens, 9019, "unpriced Claude and OpenCode rows stay unpriced")
        // 7 Standard tokens at $1, then 33 long-context Fast tokens at $2 x 10.
        Harness.expectClose(report.days[2].cost, 667, "each tier is priced at its own rates")

        let lastModels = report.days[2].models
        Harness.expectEqual(lastModels.first?.name, "priced-model", "models rank by derived cost")
        Harness.expectEqual(lastModels.first?.source, "codex", "a day's models stay split by source")
        Harness.expectEqual(lastModels.first?.total, 34, "long-context and fast tiers combine by model")
        Harness.expectEqual(lastModels.first?.cacheWrite1h, 2, "one-hour cache writes sum as a subset")
        Harness.expect(report.modelNames.contains(riskyModel), "HTML-risk model name remains intact")
        Harness.expect(!report.modelNames.contains("excluded-model"), "excluded OpenCode row stays out")
        Harness.expect(report.modelNames.contains("excluded-pi"), "formerly excluded Pi rows count under Pi Agent")
        Harness.expectEqual(Array(report.history.suffix(3)), report.days, "history ends with the selected window")
        Harness.expect(report.history.contains { $0.day == "2026-09-12" && $0.recorded },
                       "history keeps saved days before the window")
        Harness.expectEqual(report.days[2].sources.map(\.total).reduce(0, +), report.days[2].total,
                            "a day's sources add up to its total")
        Harness.expectEqual(report.days[2].models.map(\.total).reduce(0, +), report.days[2].total,
                            "a day's models add up to its total")

        let data = try JSONEncoder().encode(report)
        let encoded = String(decoding: data, as: UTF8.self)
        for identifier in ["codex-a", "codex-fast", "claude-a", "claude-b", "open-a", "pi-a"] {
            Harness.expect(!encoded.contains(identifier), "snapshot omits source paths and record identifiers")
        }
    }

    /// A usage day is priced by the period in force on that day.
    private static func pricesEachDayAtItsPeriod() throws {
        let fixture = try RecordedUsageFixture(seed: false)
        try fixture.database.exec("""
            INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns)) VALUES
              ('a', '2026-09-14', 'dated-model', 0, 0, 1000000, 0, 0, 0, 0),
              ('b', '2026-09-15', 'dated-model', 0, 0, 1000000, 0, 0, 0, 0);
            INSERT INTO claude_message (\(RecordedUsageFixture.claudeColumns)) VALUES
              ('k', 'c', '2026-09-15', 'claude-opus-5', 0, 0, 1000000, 0, 0, 0, 0);
            """)
        let book = try PriceBook(data: Data("""
            {
              "schemaVersion": 1,
              "providers": {
                "codex": {
                  "source": "https://example.com/codex", "checkedAt": "2026-09-01",
                  "models": [{
                    "id": "dated-model",
                    "periods": [
                      { "rates": { "input": 1, "output": 1 } },
                      { "from": "2026-09-15", "rates": { "input": 3, "output": 3 } }
                    ]
                  }]
                },
                "claude": {
                  "source": "https://example.com/claude", "checkedAt": "2026-09-01",
                  "models": [{ "id": "claude-opus-5", "periods": [{ "rates": { "input": 5, "output": 25 } }] }]
                }
              }
            }
            """.utf8))
        let report = try UsageReportReader.read(
            databaseURL: fixture.databaseURL,
            windowDays: 2,
            now: self.captureDate,
            calendar: self.calendar,
            rateCard: RateCard(book: book)
        )
        Harness.expectEqual(report.days.map(\.cost), [1, 8], "each day uses its own period")
        Harness.expectEqual(report.days.map(\.unpricedTokens), [0, 0], "every dated row is priced")
    }

    private static func handlesEmptyAndZeroUsage() throws {
        try self.withTemporaryDirectory { directory in
            let emptyURL = directory.appendingPathComponent("empty.sqlite")
            try TestDatabase(emptyURL).close()
            let empty = try UsageReportReader.read(
                databaseURL: emptyURL,
                windowDays: 1,
                now: self.captureDate,
                calendar: self.calendar
            )
            Harness.expectEqual(empty.days.count, 1, "requested one-day window")
            Harness.expect(!empty.days[0].recorded, "empty database has no recorded day")
            Harness.expect(!empty.hasRecordedUsage, "empty database has no usage")
            Harness.expect(empty.days[0].models.isEmpty && empty.days[0].sources.isEmpty,
                           "empty database has no models or sources")

            let zeroFixture = try RecordedUsageFixture(seed: false)
            try zeroFixture.database.exec("""
                DROP TABLE codex_day;
                DROP TABLE claude_message;
                DROP TABLE opencode_part;
                INSERT INTO pi_message (\(RecordedUsageFixture.piColumns)) VALUES
                  ('zero', 1, '2026-09-15', 'zero-model', 0, 0, 0, 0, 0, 0)
                """)
            let zero = try UsageReportReader.read(
                databaseURL: zeroFixture.databaseURL,
                windowDays: 1,
                now: self.captureDate,
                calendar: self.calendar
            )
            Harness.expectEqual(zero.windowTotal, 0, "recorded zero totals")
            Harness.expect(zero.days[0].recorded, "zero-valued row is recorded")
            Harness.expect(zero.hasRecordedUsage, "recorded zero counts as usage history")
            Harness.expectEqual(zero.days[0].models.map(\.name), ["zero-model"], "zero model remains present")
            Harness.expectEqual(zero.days[0].sources.map(\.name), ["Pi Agent"], "optional source table is readable alone")
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
            try TestDatabase(schemaURL).exec("CREATE TABLE codex_day (day TEXT)")
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

    private static func rejectsInvalidWindows() {
        Harness.expectThrows("zero-day window") {
            _ = try UsageReportReader.read(databaseURL: URL(fileURLWithPath: "/missing"), windowDays: 0)
        }
        Harness.expectThrows("window above chart limit") {
            _ = try UsageReportReader.read(databaseURL: URL(fileURLWithPath: "/missing"), windowDays: 31)
        }
    }

    private static func readsCommittedWAL() throws {
        let fixture = try RecordedUsageFixture()
        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let attributes = try FileManager.default.attributesOfItem(atPath: walURL.path)
        Harness.expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0,
                       "committed fixture data remains in a nonempty WAL with its writer open")
        try fixture.database.exec("""
            BEGIN IMMEDIATE;
            INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns)) VALUES ('uncommitted', '\(fixture.day())', 'pending', 0, 0, 700, 0, 0, 0, 0);
            """)
        let report = try self.read(fixture)
        Harness.expectEqual(report.windowTotal, 9102, "the report sees committed usage from the open writer's WAL")
        Harness.expect(!report.modelNames.contains("pending"), "uncommitted writes remain invisible")
        try fixture.database.exec("ROLLBACK; UPDATE pi_message SET input = 7 WHERE key = 'pi-a';")
        Harness.expectEqual(try self.read(fixture).windowTotal, 9103,
                            "the writer remains usable after the read-only report read")
    }

    private static func keepsSchemaAndRowsInOneSnapshot() throws {
        let fixture = try RecordedUsageFixture()
        let report = try UsageReportReader.read(
            databaseURL: fixture.databaseURL, windowDays: 4, now: fixture.now,
            calendar: fixture.calendar, rateCard: try RecordedUsageFixture.rateCard(),
            afterSchemaDiscovery: {
                // This writer commits after production schema discovery and before its token queries.
                try fixture.database.exec("""
                    BEGIN IMMEDIATE;
                    UPDATE codex_day SET input = input + 100 WHERE path = 'codex-a';
                    DROP TABLE pi_message;
                    COMMIT;
                    """)
            }
        )
        Harness.expectEqual(report.windowTotal, 9102, "one report retains the pre-commit values from every source")
        Harness.expectEqual(report.sourceTotal("Pi Agent"), 9006,
                            "schema discovery and token queries see the same version of a dropped source")
        let next = try self.read(fixture)
        Harness.expectEqual(next.windowTotal, 196, "a later report read sees the complete new committed state")
        Harness.expectEqual(next.sourceTotal("Pi Agent"), 0, "a later report read sees the dropped source")
    }

    private static func validatesRawAndAggregatedTokens() throws {
        let fixtures: [(String, String)] = [
            ("negative raw values cannot cancel", "('a', -1, 0, 0, 0, 0), ('b', 2, 0, 0, 0, 0)"),
            ("one-hour violations cannot cancel or be clamped", "('a', 0, 0, 1, 2, 0), ('b', 0, 0, 2, 0, 0)"),
            ("fractional values cannot aggregate to a valid integer", "('a', 0.5, 0, 0, 0, 0), ('b', 0.5, 0, 0, 0, 0)"),
            ("nonnumeric values cannot decode as zero", "('a', 'invalid', 0, 0, 0, 0)"),
            ("group sums must stay within the safe integer range", "('a', 9007199254740991, 0, 0, 0, 0), ('b', 1, 0, 0, 0, 0)"),
            ("disjoint bucket totals must stay within the safe integer range", "('a', 9007199254740991, 1, 0, 0, 0)"),
        ]
        for (label, values) in fixtures {
            let fixture = try RecordedUsageFixture(seed: false)
            try fixture.database.exec("""
                WITH raw(path, input, output, cache_write, cache_write_1h, cache_read) AS (VALUES \(values))
                INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns))
                SELECT path, '\(fixture.day())', 'bad', 0, 0,
                    input, output, cache_write, cache_write_1h, cache_read FROM raw;
                """)
            Harness.expectThrows(label) { _ = try self.read(fixture) }
        }

        let fixture = try RecordedUsageFixture(seed: false)
        try fixture.database.exec("""
            INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns)) VALUES
                ('safe', '\(fixture.day())', 'safe', 0, 0, 9007199254740991, 0, 0, 0, 0),
                ('old-invalid', '\(fixture.day(-3_653))', 'bad', 0, 0, -1, 0, 0, 0, 0),
                ('future-invalid', '\(fixture.day(1))', 'bad', 0, 0, -1, 0, 0, 0, 0);
            INSERT INTO opencode_part (\(RecordedUsageFixture.openCodeColumns)) VALUES
                ('excluded-invalid', 0, 0, '\(fixture.day())', 'bad', 0, 0, -1, 0, 0, 0, 0);
            """)
        Harness.expectEqual(try self.read(fixture).windowTotal, 9_007_199_254_740_991,
                            "the report validates only included rows in its bounded history")
        try fixture.database.exec("""
            INSERT INTO pi_message (\(RecordedUsageFixture.piColumns)) VALUES ('one-more', 1, '\(fixture.day())', 'other', 0, 1, 0, 0, 0, 0);
            """)
        Harness.expectThrows("cross-source presentation totals retain safe integer checks") { _ = try self.read(fixture) }

        let malformed = try RecordedUsageFixture(seed: false)
        try malformed.database.exec("DROP TABLE pi_message; CREATE VIEW pi_message AS SELECT * FROM codex_day;")
        Harness.expectThrows("supported views fail even without rows in the window") { _ = try self.read(malformed) }
    }

    private static func rejectsPartialReads() throws {
        let fixture = try RecordedUsageFixture()
        try fixture.addOverflow(source: .piAgent)
        do {
            _ = try self.read(fixture)
            Harness.expect(false, "SQLite execution failure must not return earlier source results")
        } catch UsageReportReaderError.queryFailed(let message) {
            Harness.expect(message.contains("integer overflow"), "the report propagates the SQLite stepping error")
        }
        try fixture.database.exec("DELETE FROM pi_message WHERE key IN ('overflow-a', 'overflow-b')")
        Harness.expectEqual(try self.read(fixture).windowTotal, 9102, "the report recovers after the failed source is repaired")
    }

    private static func read(_ fixture: RecordedUsageFixture) throws -> UsageReportSnapshot {
        try UsageReportReader.read(databaseURL: fixture.databaseURL, windowDays: 4,
                                   now: fixture.now, calendar: fixture.calendar,
                                   rateCard: try RecordedUsageFixture.rateCard())
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

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

/// Window sums over `days`, the way the page adds up a period.
extension UsageReportSnapshot {
    var windowTotal: Int { self.days.reduce(0) { $0 + $1.total } }
    var windowCost: Double { self.days.reduce(0) { $0 + $1.cost } }
    var windowUnpricedTokens: Int { self.days.reduce(0) { $0 + $1.unpricedTokens } }
    var modelNames: Set<String> { Set(self.days.flatMap { $0.models.map(\.name) }) }

    func sourceTotal(_ name: String) -> Int {
        self.days.flatMap(\.sources).filter { $0.name == name }.reduce(0) { $0 + $1.total }
    }
}
