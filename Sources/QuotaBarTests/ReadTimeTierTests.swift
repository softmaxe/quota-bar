import Foundation
import QuotaBarCore

enum ReadTimeTierTests {
    static func run() async throws {
        try await self.recordingAndRepricing()
        try self.datedThresholdsAndLegacyRows()
        try self.boundedAggregation()
    }

    private static func recordingAndRepricing() async throws {
        let fixture = RecorderFixture(name: "read-time-tier")
        defer { fixture.remove() }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let day = DayKey.make(from: now)
        let initial = RateCard.fixture()
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "request", model: "tier-alias", input: 100_000, output: 500_000,
                                 cacheWrite: 50_000, cacheRead: 100_000, timestamp: timestamp),
        ])
        fixture.record(.claude, rateCard: initial)
        let request = ObservedRequest(key: "request", timestamp: now, model: "tier-alias",
                                      tokens: TokenTotals(input: 100_000, output: 500_000, cacheWrite: 50_000,
                                                          cacheWrite1h: 25_000, cacheRead: 100_000), isFast: false)
        for source in [SnapshotSource.openCode, .piAgent] {
            fixture.recorder?.record(TierSnapshotAdapter(source: source, batch: [request]), rateCard: initial)
        }
        fixture.writeCodexRollout("rollout.jsonl", lines: [
            CodexLine.turnContext(model: "tier-alias"),
            CodexLine.tokenCount(input: 250_000, output: 1, total: 250_001, timestamp: timestamp),
        ])
        fixture.recorder?.record(CodexAdapter(env: fixture.env), rateCard: initial)

        let database = try TestDatabase(fixture.databaseURL)
        for table in ["claude_message", "opencode_part", "pi_message"] {
            Harness.expectEqual(try database.scalarInt("SELECT context_input FROM \(table)"), 250_000,
                                "recording stores input plus both cache buckets, excluding output and the one-hour subset")
        }
        let card = try self.card()
        Harness.expectEqual(fixture.recorder?.record(ClaudeCodeAdapter(env: fixture.env), rateCard: card), 0,
                            "a new price book does not rescan an unchanged transcript")
        for source in [SnapshotSource.openCode, .piAgent] {
            Harness.expectEqual(fixture.recorder?.record(TierSnapshotAdapter(source: source, batch: [request]), rateCard: card), 0,
                                "a new price book does not reread an unchanged snapshot")
        }
        let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
        let rows = try PricedUsage.price(try reader.reportUsage(fromDay: day, throughDay: day, rateCard: card), on: card)
        Harness.expectEqual(rows.count, 4, "each source contributes one resolved model and tier")
        for source in [CostUsageSource.claude, .openCode, .piAgent] {
            let row = rows.first { $0.source == source }
            Harness.expectEqual(row?.key.longContext, false, "a newly listed alias uses its current threshold")
            Harness.expectEqual(row?.model, "tier-model", "read-time tiering follows alias resolution")
            Harness.expectClose(row?.cost, 0.75, "output and cache-write subsets do not inflate the threshold input")
        }
        Harness.expectEqual(rows.first { $0.source == .codex }?.key.longContext, true,
                            "aggregate-only Codex keeps the tier settled when recorded")
        // Repricing is a read, not a migration or a log rescan.
        for table in ["claude_message", "opencode_part", "pi_message", "codex_day"] {
            Harness.expectEqual(try database.scalarInt("SELECT long_context FROM \(table)"), 1,
                                "read-time tiering does not overwrite the stored tier")
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("claude"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("codex"))
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: card)
        let claude = await service.refresh(.claude)
        let codex = await service.refresh(.codex)
        Harness.expectClose(claude?.windowCostUSD, 0.75, "the menu retiers keyed usage even after logs disappear")
        Harness.expectClose(codex?.windowCostUSD, 1.250002, "the menu retiers snapshot usage and retains Codex's tier")
        let report = try UsageReportReader.read(databaseURL: fixture.databaseURL, now: now, rateCard: card)
        Harness.expectClose(report.days.reduce(0) { $0 + $1.cost }, 2.750002,
                            "the report and menu price the same read-time tiers")

        // Real content growth replaces the context measurement together with the usage.
        var grown = request
        grown.tokens = TokenTotals(input: 300_000, output: 600_000)
        for source in [SnapshotSource.openCode, .piAgent] {
            fixture.recorder?.record(TierSnapshotAdapter(source: source, batch: [grown], stamp: 2), rateCard: card)
        }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "request", model: "tier-alias", input: 300_000, output: 600_000, timestamp: timestamp),
        ])
        fixture.record(.claude, rateCard: card)
        for table in ["claude_message", "opencode_part", "pi_message"] {
            Harness.expectEqual(try database.scalarInt("SELECT context_input FROM \(table)"), 300_000,
                                "content updates replace the request context measurement")
            try database.exec("UPDATE \(table) SET context_input = NULL")
        }
        // A legacy row replayed unchanged must not acquire a context value as a side effect.
        for source in [SnapshotSource.openCode, .piAgent] {
            fixture.recorder?.record(TierSnapshotAdapter(source: source, batch: [grown], stamp: 3), rateCard: card)
        }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "request", model: "tier-alias", input: 300_000, output: 600_000, timestamp: timestamp),
        ])
        fixture.record(.claude, rateCard: card)
        for table in ["claude_message", "opencode_part", "pi_message"] {
            Harness.expectEqual(try database.scalarInt("SELECT COUNT(*) FROM \(table) WHERE context_input IS NOT NULL"), 0,
                                "unchanged replays do not backfill legacy context")
        }
    }

    private static func datedThresholdsAndLegacyRows() throws {
        let fixture = try RecordedUsageFixture(seed: false)
        let database = fixture.database
        try database.exec("""
            INSERT INTO claude_message (\(RecordedUsageFixture.claudeColumns), context_input) VALUES
            ('before', '', '2026-09-01', 'tier-alias', 1, 0, 250000, 0, 0, 0, 0, 250000),
            ('after', '', '2026-09-02', 'tier-alias', 0, 0, 250000, 0, 0, 0, 0, 250000),
            ('boundary', '', '2026-09-01', 'tier-model', 1, 0, 272000, 0, 0, 0, 0, 272000),
            ('above', '', '2026-09-01', 'tier-model', 0, 0, 272001, 0, 0, 0, 0, 272001),
            ('small-a', '', '2026-09-01', 'tier-model', 0, 0, 150000, 0, 0, 0, 0, 150000),
            ('small-b', '', '2026-09-01', 'tier-model', 0, 0, 150000, 0, 0, 0, 0, 150000),
            ('fast', '', '2026-09-01', 'tier-alias', 0, 1, 272001, 0, 0, 0, 0, 272001),
            ('legacy-long', '', '2026-09-01', 'tier-alias', 1, 0, 1, 0, 0, 0, 0, NULL),
            ('legacy-base', '', '2026-09-01', 'tier-alias', 0, 0, 900000, 0, 0, 0, 0, NULL);
            """)
        let card = try self.card(dated: true)
        let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
        let rows = try PricedUsage.price(
            try reader.reportUsage(fromDay: "2026-09-01", throughDay: "2026-09-02", rateCard: card), on: card)
        Harness.expectEqual(Set(rows.map(\.key)).count, rows.count, "pricing emits one row per day/source/model/tier/Fast key")
        Harness.expectEqual(rows.count, 4, "threshold buckets and aliases coalesce after classification")
        Harness.expectEqual(rows.first { $0.day == "2026-09-01" && !$0.key.longContext }?.tokens.input, 1_722_000,
                            "exact-threshold and small requests stay base; legacy base stays base")
        Harness.expectEqual(rows.first { $0.day == "2026-09-01" && $0.key.longContext && !$0.key.isFast }?.tokens.input, 272_002,
                            "above-threshold usage and legacy long-context usage share the long tier")
        Harness.expectClose(rows.first { $0.key.isFast }?.cost, 1.088004, "Fast pricing uses the reclassified tier")
        Harness.expectEqual(rows.first { $0.day == "2026-09-02" }?.key.longContext, true,
                            "thresholds use each recorded day's price period")
        let menuRows = try PricedUsage.price(
            try reader.dailyUsage(tab: .claude, fromDay: "2026-09-01", rateCard: card), on: card)
        Harness.expectEqual(menuRows, rows, "both reading paths apply the same thresholds and legacy fallback")

        for value in ["-1", "1.5", "'invalid'"] {
            try database.exec("UPDATE claude_message SET context_input = \(value) WHERE key = 'before'")
            Harness.expectThrows("invalid threshold inputs cannot silently change pricing") {
                _ = try reader.reportUsage(fromDay: "2026-09-01", throughDay: "2026-09-02", rateCard: card)
            }
        }
    }

    private static func boundedAggregation() throws {
        let fixture = try RecordedUsageFixture(seed: false)
        try fixture.database.exec("""
            WITH RECURSIVE requests(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM requests WHERE n < 10000)
            INSERT INTO pi_message (\(RecordedUsageFixture.piColumns), context_input)
            SELECT 'request-' || n, 1, '2026-09-01', 'tier-alias', 0, n * 40, 0, 0, 0, 0, n * 40 FROM requests;
            """)
        let card = try self.card()
        let rows = try RecordedUsageReader(databaseURL: fixture.databaseURL)
            .dailyUsage(tab: .pi, fromDay: "2026-09-01", rateCard: card)
        Harness.expect(rows.count <= 3, "SQL aggregates thousands of distinct request sizes into threshold buckets")
        let priced = try PricedUsage.price(rows, on: card)
        Harness.expectEqual(priced.count, 2, "only the two effective tiers reach pricing consumers")
        Harness.expectEqual(priced.reduce(0) { $0 + $1.tokens.input }, 2_000_200_000,
                            "bounded aggregation preserves all request tokens")
    }

    private static func card(dated: Bool = false) throws -> RateCard {
        let later = dated ? #", {"from":"2026-09-02","rates":{"input":1,"output":1,"thresholdTokens":225000,"inputAbove":2,"outputAbove":2},"fastMultiplier":2}"# : ""
        let model = #"{"id":"tier-model","aliases":["tier-alias"],"periods":[{"rates":{"input":1,"output":1,"cacheWrite":1,"cacheWrite1h":1,"cacheRead":1,"thresholdTokens":272000,"inputAbove":2,"outputAbove":2},"fastMultiplier":2}\#(later)]}"#
        let section = #"{"source":"https://example.com","checkedAt":"2026-09-01","models":[\#(model)]}"#
        return RateCard(book: try PriceBook(data: Data(
            #"{"schemaVersion":1,"providers":{"claude":\#(section),"codex":\#(section)}}"#.utf8)))
    }
}

private struct TierSnapshotAdapter: SnapshotAdapter {
    let source: SnapshotSource
    let batch: [ObservedRequest]
    var stamp = 1

    func survey() -> SnapshotSurvey<Int> { .present(stamp: self.stamp, included: true, status: .idle) }
    func requests() throws -> [ObservedRequest] { self.batch }
}
