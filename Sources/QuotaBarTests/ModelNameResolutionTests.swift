import Foundation
import QuotaBarCore

/// Model names are resolved to model IDs when Recorded usage is read, against the rate card of
/// that read. Usage recorded before a price book listed its alias picks up the model's rates
/// once a later book does, without rescanning.
enum ModelNameResolutionTests {
    static func run() async {
        await Self.aliasInALaterPriceBookPricesRecordedUsage()
    }

    private static func book(aliases: [String]) -> PriceBook? {
        let aliasList = aliases.map { "\"\($0)\"" }.joined(separator: ", ")
        do {
            return try PriceBook(data: Data("""
                {
                  "schemaVersion": 1,
                  "providers": {
                    "codex": {
                      "source": "https://example.com", "checkedAt": "2026-09-01",
                      "models": [ { "id": "codex-fixture", "periods": [ { "rates": { "input": 1, "output": 1 } } ] } ]
                    },
                    "claude": {
                      "source": "https://example.com", "checkedAt": "2026-09-01",
                      "models": [
                        { "id": "claude-later", "aliases": [\(aliasList)], "periods": [ { "rates": { "input": 1, "output": 1 } } ] }
                      ]
                    }
                  }
                }
                """.utf8))
        } catch {
            Harness.expect(false, "model name fixture book threw: \(error)")
            return nil
        }
    }

    /// Recorded under a book without the alias, read under one that adds it: the usage is
    /// priced and grouped under the canonical model in the menu, the usage report, and the
    /// pricing settings alike. Dated and vendor-prefixed spellings and rows already stored
    /// under the model ID all land on the same model.
    private static func aliasInALaterPriceBookPricesRecordedUsage() async {
        guard let before = Self.book(aliases: []), let after = Self.book(aliases: ["claude-alias"]) else { return }
        let fixture = RecorderFixture(name: "read-time-alias")
        defer { fixture.remove() }
        let now = ISO8601DateFormatter().string(from: Date())
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "plain", model: "claude-alias", input: 1_000_000, output: 0, timestamp: now),
            ClaudeLine.assistant(id: "dated", model: "claude-alias-20260101", input: 1_000_000, output: 0, timestamp: now),
            ClaudeLine.assistant(id: "vendor", model: "anthropic.claude-alias-v1:0", input: 1_000_000, output: 0, timestamp: now),
            ClaudeLine.assistant(id: "canonical", model: "claude-later", input: 1_000_000, output: 0, timestamp: now),
        ])

        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: RateCard(book: before))
        let recorded = await service.refresh(.claude)
        Harness.expect(recorded?.hasUnpricedTokens == true, "the alias is Unpriced usage under a book that does not list it")

        let laterCard = RateCard(book: after)
        await service.useRateCard(laterCard)
        guard let menu = await service.refresh(.claude) else {
            Harness.expect(false, "the refresh under the later book returned no snapshot")
            return
        }
        Harness.expect(!menu.hasUnpricedTokens, "the menu prices the alias once a later book lists it")
        Harness.expectEqual(menu.windowCostUSD, 4, "every spelling is priced at the canonical model's rates")
        Harness.expectEqual(menu.topModel, "claude-later", "the menu names the canonical model")
        Harness.expectEqual(
            Set(menu.days.flatMap { $0.byModel.keys.map(\.model) }),
            ["claude-later"],
            "the menu groups every spelling under the canonical model"
        )

        do {
            let report = try UsageReportReader.read(databaseURL: fixture.databaseURL, rateCard: laterCard)
            Harness.expectEqual(report.models.map(\.name), ["claude-later"], "the report groups every spelling under the canonical model")
            Harness.expectEqual(report.totals.unpricedTokens, 0, "the report prices the alias")
            Harness.expectEqual(report.totals.cost, 4, "the report agrees with the menu's cost")
        } catch {
            Harness.expect(false, "reading the usage report threw: \(error)")
        }

        do {
            // The pricing settings regroup the recorded usage with `RateCard.modelUsage` and look
            // each model's rates up by the ID it returns.
            let usage = laterCard.modelUsage(try await service.knownModelUsage(provider: .claude), provider: .claude)
            Harness.expectEqual(
                usage,
                [ModelUsageTotal(model: "claude-later", tokens: 4_000_000)],
                "the pricing settings add the alias, its spellings, and the model ID into one model"
            )
            Harness.expect(
                laterCard.rates(for: "claude-later", provider: .claude, day: DayKey.today()) != nil,
                "the pricing settings agree that the model is priced"
            )
        } catch {
            Harness.expect(false, "reading known model usage threw: \(error)")
        }
    }
}
