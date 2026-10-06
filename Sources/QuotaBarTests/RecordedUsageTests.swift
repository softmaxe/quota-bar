import Foundation
import QuotaBarCore

enum RecordedUsageTests {
    static func run() async {
        do {
            try self.dailyUsage()
            try self.modelUsage()
            try self.queryFailures()
            try self.menuNumericPolicy()
            try await self.menuProjectionAndRecovery()
        } catch {
            Harness.expect(false, "recorded usage tests threw: \(error)")
        }
    }

    private static func modelUsage() throws {
        let fixture = try RecordedUsageFixture()
        let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
        let models = try reader.modelUsage(provider: .codex)
        Harness.expectEqual(Dictionary(uniqueKeysWithValues: models.map { ($0.model, $0.tokens) }), [
            "priced-model": 68, "old-model": 1_000, "future-model": 1_000,
            "unpriced-model": 14, "zero-model": 0,
        ], "model usage includes all history, eligible sources, both tiers, and recorded zero")
        Harness.expectEqual(try reader.modelUsage(provider: .claude), [ModelUsageTotal(model: "claude-model", tokens: 20)],
                            "Claude cumulative usage stays separate")
        Harness.expectEqual(models.map(\.tokens), models.map(\.tokens).sorted(by: >),
                            "model usage remains ordered by cumulative tokens")
        try fixture.execute("""
            INSERT INTO pi_message VALUES
            ('unknown', 1, '\(fixture.day())', '\(CostPricing.unknownModel)', 0, 99, 0, 0, 0, 0);
            """)
        let visible = try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: fixture.databaseURL)
        Harness.expectEqual(Dictionary(uniqueKeysWithValues: visible.map { ($0.model, $0.tokens) }),
                            Dictionary(uniqueKeysWithValues: models.map { ($0.model, $0.tokens) }),
                            "Pricing excludes the unknown-model sentinel")

        let absent = fixture.directory.appendingPathComponent("absent/usage.sqlite")
        Harness.expectEqual(try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: absent), [],
                            "a genuinely absent database is normal empty Pricing usage")
        Harness.expect(!FileManager.default.fileExists(atPath: absent.path), "Pricing does not create its absent database")
        Harness.expectThrows("an existing path that cannot open as SQLite must not become empty success") {
            _ = try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: fixture.directory)
        }
        let corrupt = fixture.directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        Harness.expectThrows("corrupt Pricing usage must not become empty success") {
            _ = try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: corrupt)
        }
        for (source, seed) in [(CostUsageSource.codex, false), (.piAgent, true)] {
            let failing = try RecordedUsageFixture(seed: seed)
            try failing.addOverflow(source: source)
            do {
                _ = try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: failing.databaseURL)
                Harness.expect(false, "model query stepping failure returned empty or partial success")
            } catch RecordedUsageReaderError.queryFailed(let message) {
                Harness.expect(message.contains("integer overflow"), "model usage propagates SQLite stepping failures")
            }
        }
        try fixture.execute("DROP TABLE pi_message")
        Harness.expectThrows("Pricing continues to require every provider source table") {
            _ = try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: fixture.databaseURL)
        }
    }

    private static func dailyUsage() throws {
        let fixture = try RecordedUsageFixture()
        let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
        let codex = try reader.dailyUsage(provider: .codex, fromDay: fixture.day(-3), rateCard: RateCard())
        Harness.expectEqual(Set(codex.keys), Set([fixture.day(-3), fixture.day(-2), fixture.day(), fixture.day(1)]),
                            "daily usage keeps recorded zero and future days but does not invent missing days")
        let earlier = codex[fixture.day(-2)]?.values.first
        Harness.expectEqual(earlier, TokenTotals(input: 15, output: 3, cacheWrite: 6, cacheWrite1h: 2, cacheRead: 4),
                            "daily usage sums every token column in matching buckets")
        let today = codex[fixture.day()] ?? [:]
        Harness.expectEqual(Set(today.keys.map(\.source)), Set([.codex, .openCode, .piAgent]),
                            "Codex groups eligible sources while retaining their identity")
        Harness.expectEqual(today.count, 4, "Standard and Fast retain separate recorded buckets")
        Harness.expectEqual(today.first { $0.key.source == .codex && $0.key.isFast }?.value.total, 33,
                            "Fast recorded tokens survive grouping")
        Harness.expect(today.keys.contains { $0.source == .codex && $0.isFast && $0.longContext },
                       "the recorded Long-context tier survives even below the current threshold")
        Harness.expectEqual(today.values.reduce(0) { $0 + $1.total }, 54,
                            "excluded external rows do not count")
        Harness.expectEqual(codex[fixture.day(-3)]?.values.first?.total, 0, "recorded zero usage survives")

        let claude = try reader.dailyUsage(provider: .claude, fromDay: fixture.day(-3), rateCard: RateCard())
        Harness.expectEqual(Set(claude.values.flatMap { $0.keys.map(\.source) }), Set([.claude]),
                            "Claude stays in its own provider grouping")
        Harness.expectEqual(claude.values.flatMap { $0.values }.reduce(0) { $0 + $1.total }, 20,
                            "Claude includes both stored tiers")
        Harness.expect(claude.values.flatMap { $0.keys }.allSatisfy { !$0.isFast },
                       "Claude rows recorded as Standard stay Standard")

        try fixture.execute("""
            INSERT INTO claude_message VALUES
            ('claude-fast', 'claude-fast', '\(fixture.day())', 'claude-model', 0, 1, 9, 1, 0, 0, 0);
            """)
        let claudeToday = try reader.dailyUsage(provider: .claude, fromDay: fixture.day(), rateCard: RateCard())[fixture.day()] ?? [:]
        Harness.expectEqual(claudeToday.first { $0.key.isFast }?.value.total, 10,
                            "Claude Fast mode keeps its own recorded bucket")
        Harness.expectEqual(claudeToday.count, 2, "Claude Standard and Fast stay separate")
    }

    private static func queryFailures() throws {
        for (source, seed) in [(CostUsageSource.codex, false), (.codex, true), (.piAgent, true)] {
            let fixture = try RecordedUsageFixture(seed: seed)
            try fixture.addOverflow(source: source)
            let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
            do {
                _ = try reader.dailyUsage(provider: .codex, fromDay: fixture.day(-3), rateCard: RateCard())
                Harness.expect(false, "\(source) execution failure returned empty or partial daily usage")
            } catch RecordedUsageReaderError.queryFailed(let message) {
                Harness.expect(message.contains("integer overflow"),
                               "SQLite stepping failure propagates, including after prior sources completed")
            }
        }

        let fixture = try RecordedUsageFixture(seed: false)
        try fixture.execute("DROP TABLE pi_message")
        let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
        Harness.expectThrows("menu reads continue to require every provider source table") {
            _ = try reader.dailyUsage(provider: .codex, fromDay: fixture.day(), rateCard: RateCard())
        }
        let absent = fixture.directory.appendingPathComponent("absent.sqlite")
        Harness.expectThrows("the shared reader propagates open failures") {
            _ = try RecordedUsageReader(databaseURL: absent)
        }
        Harness.expect(!FileManager.default.fileExists(atPath: absent.path), "a read does not create a database")
    }

    private static func menuNumericPolicy() throws {
        let fixture = try RecordedUsageFixture(seed: false)
        let large = 9_007_199_254_740_992
        try fixture.execute("""
            INSERT INTO codex_day VALUES ('large', '\(fixture.day())', 'large', 0, 0, \(large), 0, 0, 0, 0);
            """)
        let rows = try RecordedUsageReader(databaseURL: fixture.databaseURL)
            .dailyUsage(provider: .codex, fromDay: fixture.day(), rateCard: RateCard())
        Harness.expectEqual(rows[fixture.day()]?.values.first?.input, large,
                            "menu reads do not inherit export's JavaScript safe-integer limit")
        Harness.expectEqual(try CostUsageReader.knownModelUsage(provider: .codex, databaseURL: fixture.databaseURL),
                            [ModelUsageTotal(model: "large", tokens: large)],
                            "Pricing does not inherit export's JavaScript safe-integer limit")
    }

    private static func menuProjectionAndRecovery() async throws {
        let fixture = try RecordedUsageFixture(now: Date(), calendar: .current)
        let service = CostService(databaseURL: fixture.databaseURL, env: isolatedEnvironment(root: fixture.directory),
                                  rateCard: try RecordedUsageFixture.rateCard())
        let first = await service.refresh(.codex)
        Harness.expectEqual(first?.windowTokens, 1_082, "menu retains its lower date bound and future-day usage")
        Harness.expectEqual(first?.latestTokens, 1_000, "future usage remains the latest menu day")
        Harness.expectClose(first?.windowCostUSD, 695, "menu prices Standard, Fast, and recorded Long-context usage")
        Harness.expectClose(first?.todayCostUSD, 667, "menu prices today's matching source grouping")
        Harness.expectEqual(first?.topModel, "priced-model", "menu ranks models by priced usage")
        Harness.expectEqual(first?.hasUnpricedTokens, true, "menu retains Unpriced usage")
        Harness.expectEqual(first?.days.first(where: { $0.dayKey == fixture.day() })?.unpricedTokens, 14,
                            "unpriced external usage contributes tokens without a cost")
        Harness.expectEqual(first?.days.first(where: { $0.dayKey == fixture.day(-3) })?.tokens.total, 0,
                            "menu retains a recorded zero day")

        let claude = await service.refresh(.claude)
        let report = try UsageReportReader.read(databaseURL: fixture.databaseURL, windowDays: 30,
                                               now: fixture.now, calendar: fixture.calendar,
                                               rateCard: try RecordedUsageFixture.rateCard())
        let codexSources = report.sources.filter { $0.name != CostUsageSource.claude.displayName }
        Harness.expectEqual(codexSources.reduce(0) { $0 + $1.total }, 82,
                            "export's matching Codex sources exclude the menu's 1,000 future tokens")
        Harness.expectClose(codexSources.reduce(0) { $0 + $1.cost }, first?.windowCostUSD ?? -1,
                            "matching priced records use the same Rate card in menu and export")
        Harness.expectEqual(report.sources.map(\.name), ["Codex", "Claude", "OpenCode", "Pi Agent"],
                            "shared source identities preserve export display order")
        for day in report.days {
            let matchingDays = [first, claude].compactMap { $0?.days.first { $0.dayKey == day.day } }
            Harness.expectEqual(day.total, matchingDays.reduce(0) { $0 + $1.tokens.total },
                                "menu and export agree on all-source tokens for overlapping day \(day.day)")
            Harness.expectEqual(day.unpricedTokens, matchingDays.reduce(0) { $0 + $1.unpricedTokens },
                                "menu and export agree on Unpriced usage for overlapping day \(day.day)")
            Harness.expectClose(day.cost, matchingDays.reduce(0) { $0 + ($1.costUSD ?? 0) },
                                "menu and export agree on cost for overlapping day \(day.day)")
            Harness.expectEqual(day.recorded, !matchingDays.isEmpty,
                                "export distinguishes missing and recorded zero days from shared records")
        }

        try fixture.addOverflow(source: .piAgent)
        let failed = await service.refresh(.codex)
        Harness.expect(failed == nil, "CostService reports late query failure instead of a partial success")
        try fixture.execute("DELETE FROM pi_message WHERE key IN ('overflow-a', 'overflow-b')")
        try fixture.execute("UPDATE pi_message SET input = 7 WHERE key = 'pi-a'")
        let recovered = await service.refresh(.codex)
        Harness.expectEqual(recovered?.windowTokens, 1_083, "CostService can read again after query failure")
        Harness.expectClose(recovered?.windowCostUSD, 696, "a successful retry returns the current complete snapshot")
    }
}
