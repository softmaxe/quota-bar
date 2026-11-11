import Foundation
@testable import QuotaBarCore

/// Boundary regressions reject invalid accounting without trapping or losing scan progress.
enum TokenValidationTests {
    static func run() {
        Harness.expect(TokenTotals(input: Int.max).hasValidCounts, "one maximum bucket is representable")
        Harness.expect(!TokenTotals(input: Int.max, output: 1).hasValidCounts, "cross-bucket overflow is invalid")
        Harness.expect(!TokenTotals(input: -1).hasValidCounts, "negative tokens are invalid")
        Harness.expectThrows("checked aggregation rejects overflow") {
            _ = try TokenTotals(input: Int.max).adding(TokenTotals(output: 1))
        }
        Harness.expectEqual(try? TokenTotals(input: 10).adding(TokenTotals(output: 2)),
                            TokenTotals(input: 10, output: 2), "ordinary aggregation is exact")
        Harness.expectEqual(TokenTotals(input: Int.max, output: 1).total, Int.max,
                            "presentation total is bounded for directly constructed invalid models")
        do {
            try Self.aliasAggregation()
            try Self.readerRejectsInvalidRows()
            try Self.recordingOverflowRollsBack()
            Self.scannerMakesProgress()
        } catch {
            Harness.expect(false, "token validation regression threw: \(error)")
        }
    }

    private static func aliasAggregation() throws {
        let rows = (0..<1_025).map { index in
            RecordedUsageReader.DayUsage(day: "2026-09-01",
                tier: .init(source: .codex, model: "vendor\(index)/gpt-5.1", longContext: false, isFast: false),
                tokens: TokenTotals(input: Int(RecordedUsageReader.reportMaximumSafeInteger)))
        }
        Harness.expectThrows("canonical alias aggregation rejects overflow before pricing") {
            _ = try PricedUsage.price(rows, on: RateCard())
        }
        let ordinary = RecordedUsageReader.DayUsage(day: "2026-09-01",
            tier: .init(source: .codex, model: "gpt-5.1", longContext: false, isFast: false),
            tokens: TokenTotals(input: 10))
        Harness.expectEqual(try PricedUsage.price([ordinary, ordinary], on: RateCard()).first?.tokens.input,
                            20, "ordinary aliases still aggregate exactly")
    }

    private static func readerRejectsInvalidRows() throws {
        for input in ["-1", "'bad'", "1.5"] {
            let fixture = try RecordedUsageFixture(seed: false)
            try fixture.database.exec("""
                INSERT INTO codex_day (\(RecordedUsageFixture.codexColumns)) VALUES
                ('invalid', '\(fixture.day())', 'gpt-5.1', 0, 0, \(input), 0, 0, 0, 0);
                """)
            let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
            Harness.expectThrows("menu rejects invalid raw token domain") {
                _ = try reader.dailyUsage(tab: .codex, fromDay: fixture.day())
            }
            Harness.expectThrows("report rejects invalid raw token domain") {
                _ = try reader.reportUsage(fromDay: fixture.day(), throughDay: fixture.day())
            }
            Harness.expectThrows("Pricing rejects invalid raw token domain") {
                _ = try reader.modelUsage(tab: .codex)
            }
        }
    }

    private static func recordingOverflowRollsBack() throws {
        for output in [0, 1] {
            let fixture = RecorderFixture(name: "codex-checked-merge-\(output)")
            defer { fixture.remove() }
            let path = "2026/09/01/rollout-2026-09-01T12-00-00-0199a000-0000-7000-8000-000000000009.jsonl"
            let originalInput = output == 0 ? Int.max : Int.max - 300_000
            fixture.writeCodexRollout(path, lines: [
                CodexLine.turnContext(model: "gpt-5.6-sol"),
                CodexLine.tokenCount(input: originalInput, output: 0, total: 1),
            ])
            fixture.record(.codex)
            let database = try TestDatabase(fixture.databaseURL)
            let offset = try database.scalarInt("SELECT offset FROM file_cursor LIMIT 1")
            fixture.appendCodexRollout(path, lines: [
                CodexLine.tokenCount(input: 300_000, output: output, total: 2),
            ])
            fixture.record(.codex)
            Harness.expectEqual(try database.scalarInt("SELECT input FROM codex_day"), originalInput,
                                "overflow rolls back persisted tokens")
            Harness.expectEqual(try database.scalarInt("SELECT typeof(input) = 'integer' FROM codex_day"), 1,
                                "recording never promotes token storage to REAL")
            Harness.expectEqual(try database.scalarInt("SELECT offset FROM file_cursor LIMIT 1"), offset,
                                "overflow rolls back the scan cursor")
            let reopened = try UsageRecorder(databaseURL: fixture.databaseURL)
            reopened.record(.codex, rateCard: RateCard(), env: fixture.env)
            let reader = try RecordedUsageReader(databaseURL: fixture.databaseURL)
            Harness.expectEqual(try reader.dailyUsage(tab: .codex, fromDay: "2026-01-01").first?.tokens.input,
                                originalInput, "reopening after overflow keeps valid prior usage readable")
        }
    }

    private static func scannerMakesProgress() {
        let fixture = RecorderFixture(name: "invalid-token-progress")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "invalid", model: "claude-tier", input: Int.max, output: 1),
            ClaudeLine.assistant(id: "negative", model: "claude-tier", input: -1, output: 2),
            ClaudeLine.assistant(id: "ordinary", model: "claude-tier", input: 10, output: 2),
        ])
        fixture.record(.claude)
        let tier = RecordedTier(model: "claude-tier", longContext: false, isFast: false)
        Harness.expectEqual(fixture.recorded(.claude)[tier], TokenTotals(input: 10, output: 2),
                            "invalid lines are skipped without losing later valid usage")
        fixture.record(.claude)
        Harness.expectEqual(fixture.recorded(.claude)[tier], TokenTotals(input: 10, output: 2),
                            "rescanning rejected lines neither repeats usage nor stalls progress")
    }
}
