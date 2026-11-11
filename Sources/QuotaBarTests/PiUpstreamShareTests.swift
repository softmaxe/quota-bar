@testable import QuotaBarApp
import Foundation
import QuotaBarCore

/// How the Pi card splits a window across upstream providers.
enum PiUpstreamShareTests {
    static func run() {
        func usage(_ tokens: Int, _ cost: Double?) -> ModelDayUsage {
            ModelDayUsage(tokens: TokenTotals(input: tokens, output: 0, cacheWrite: 0, cacheWrite1h: 0, cacheRead: 0), costUSD: cost)
        }
        func key(_ model: String, _ upstream: String?) -> ModelUsageKey {
            ModelUsageKey(source: .piAgent, model: model, upstreamProvider: upstream)
        }
        func snapshot(_ days: [[ModelUsageKey: ModelDayUsage]]) -> CostSnapshot {
            CostSnapshot(
                tab: .pi,
                days: days.enumerated().map { index, models in
                    CostDay(dayKey: String(format: "2026-11-%02d", index + 1), byModel: models, costUSD: nil, unpricedTokens: 0)
                },
                todayCostUSD: 0, windowCostUSD: 0, latestTokens: 0, windowTokens: 0, topModel: nil,
                hasUnpricedTokens: false, scannedAt: Date(timeIntervalSince1970: 0)
            )
        }

        // One model sold by two providers stays two shares; one provider's days and models add up.
        let mixed = snapshot([
            [key("sonnet", "anthropic"): usage(100, 4), key("sonnet", "openrouter"): usage(900, 1)],
            [key("opus", "anthropic"): usage(50, 6), key("local", nil): usage(10, nil)],
        ])
        let byCost = PiUpstreamSectionView.shares(of: mixed, by: .cost)
        Harness.expectEqual(byCost.map(\.id), ["anthropic", "openrouter", ""], "cost ranking")
        Harness.expectEqual(byCost.first?.costUSD, 10, "a provider's cost sums across days and models")
        Harness.expect(byCost.last?.hasUnpricedUsage == true, "usage without a price was reported as priced")
        let byTokens = PiUpstreamSectionView.shares(of: mixed, by: .tokens)
        Harness.expectEqual(byTokens.first?.id, "openrouter", "the unit did not change the ranking")

        // Past the visible rows the tail folds into one share, and nothing is dropped from the total.
        let many = snapshot([Dictionary(uniqueKeysWithValues: (1...7).map { (key("m", "p\($0)"), usage($0, Double($0))) })])
        let folded = PiUpstreamSectionView.shares(of: many, by: .cost)
        Harness.expectEqual(folded.count, 5, "seven providers did not fold into four rows and a remainder")
        Harness.expectEqual(folded.reduce(0) { $0 + $1.costUSD }, 28, "folding lost usage")
        // Five providers fit without a remainder row standing in for a single provider.
        let five = snapshot([Dictionary(uniqueKeysWithValues: (1...5).map { (key("m", "p\($0)"), usage($0, Double($0))) })])
        Harness.expectEqual(PiUpstreamSectionView.shares(of: five, by: .cost).count, 5, "five providers")
        Harness.expect(!PiUpstreamSectionView.shares(of: five, by: .cost).contains { $0.name.hasSuffix("more") },
                       "a lone provider was folded into a remainder")
    }
}
