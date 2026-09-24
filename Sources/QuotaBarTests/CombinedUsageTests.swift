import QuotaBarCore
import Foundation

/// Local usage from both providers read as one day and one window.
enum CombinedUsageTests {
    static func run() {
        let codexKey = ModelUsageKey(source: .codex, model: "gpt-5.5")
        let claudeKey = ModelUsageKey(source: .claude, model: "claude-opus-5-5")
        let codexDay = CostDay(
            dayKey: "2026-09-23",
            byModel: [codexKey: ModelDayUsage(tokens: TokenTotals(input: 300, output: 100), costUSD: 2.5)],
            costUSD: 2.5,
            unpricedTokens: 0
        )
        let unpricedClaudeDay = CostDay(
            dayKey: "2026-09-23",
            byModel: [claudeKey: ModelDayUsage(tokens: TokenTotals(input: 600), costUSD: nil)],
            costUSD: nil,
            unpricedTokens: 600
        )

        let combined = CostDay.combining([codexDay, unpricedClaudeDay], dayKey: "2026-09-23")
        Harness.expectEqual(combined.tokens.total, 1_000, "combined day counts both providers' tokens")
        Harness.expectEqual(combined.byModel.count, 2, "combined day keeps each provider's models")
        Harness.expectEqual(combined.costAvailability.state, .partial, "one unpriced provider makes the day partial")
        Harness.expectClose(combined.costAvailability.knownUSD, 2.5, "partial day keeps the priced provider's cost")
        Harness.expectEqual(combined.costAvailability.unpricedTokens, 600, "partial day reports the unpriced tokens")

        let bothUnpriced = CostDay.combining([unpricedClaudeDay, unpricedClaudeDay], dayKey: "2026-09-23")
        Harness.expectEqual(bothUnpriced.costAvailability.state, .unpriced, "no priced usage stays unpriced")

        let empty = CostDay.combining([], dayKey: "2026-09-22")
        Harness.expectEqual(empty.costAvailability, .zero, "a day nobody used is a known zero")

        let scannedAt = Date(timeIntervalSince1970: 1_790_000_000)
        func snapshot(_ provider: Provider, _ days: [CostDay], cost: Double) -> CostSnapshot {
            CostSnapshot(
                provider: provider,
                days: days,
                todayCostUSD: 0,
                windowCostUSD: cost,
                latestTokens: 0,
                windowTokens: days.reduce(0) { $0 + $1.tokens.total },
                topModel: nil,
                hasUnpricedTokens: false,
                scannedAt: scannedAt
            )
        }
        let window = CostAvailability.window(of: [
            snapshot(.codex, [codexDay], cost: 2.5),
            snapshot(.claude, [unpricedClaudeDay], cost: 0),
        ])
        Harness.expectEqual(window.state, .partial, "an unpriced provider makes the combined window partial")
        Harness.expectClose(window.knownUSD, 2.5, "the combined window sums priced cost")
        Harness.expectEqual(window.unpricedTokens, 600, "the combined window sums unpriced tokens")
    }
}
