@testable import QuotaBarApp
import QuotaBarCore
import Foundation

/// Checks column sorting, blank rates, and reset to configured model order.
@MainActor
enum PricingSortTests {
    static func run() {
        let model = PricingTableModel(costService: CostService())
        model.debugSetRows([
            Self.row("claude-opus-4", usageTokens: 900, input: 15, output: 75, cacheRead: 1.5, settingsRank: 1),
            Self.row("claude-haiku-4", usageTokens: 5_000, input: 1, output: 5, cacheRead: 0.1),
            Self.row("claude-sonnet-4", usageTokens: 20, input: 3, output: 15, cacheRead: 0.3, settingsRank: 0),
            // Seen in the logs but priced nowhere, which is the row a rate sort has to place.
            Self.row("claude-next", usageTokens: 40, input: nil, output: nil, cacheRead: nil),
            Self.row("other-z", usageTokens: 900, input: nil, output: nil, cacheRead: nil, group: .others),
            Self.row("other-a", usageTokens: 10, input: nil, output: nil, cacheRead: nil, group: .others),
        ])

        func names() -> [String] { model.rows(in: .claude).map(\.model) }
        func others() -> [String] { model.rows(in: .others).map(\.model) }

        // Configured ranks precede usage; unranked rows use token totals.
        let defaultOrder = ["claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-next"]
        let othersByUsage = ["other-z", "other-a"]
        Harness.expectEqual(names(), defaultOrder, "the pane uses configured ranks, then usage")
        Harness.expectEqual(others(), othersByUsage, "Others are ordered by usage")

        // A rate column opens on the expensive end: that is the number a price table is opened for.
        model.toggleSort(.input)
        Harness.expect(!model.sort.ascending, "the first click on Input points descending")
        Harness.expectEqual(names(), ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-next"],
                            "the first click on Input puts the expensive end first")

        // Flipped, the unpriced row still sinks: an empty rate is unknown, not zero.
        model.toggleSort(.input)
        Harness.expect(model.sort.ascending, "the second click on Input points ascending")
        Harness.expectEqual(names(), ["claude-haiku-4", "claude-sonnet-4", "claude-opus-4", "claude-next"],
                            "the second click on Input still sinks the unpriced row")

        model.toggleSort(.cacheRead)
        Harness.expectEqual(model.sort.field, .cacheRead, "Cache r sorts by cache reads")
        Harness.expectEqual(names(), ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-next"],
                            "Cache r puts the expensive end first")

        // A name column opens A→Z instead, since that is what reading a list of names wants.
        model.toggleSort(.model)
        let alphabetical = ["claude-haiku-4", "claude-next", "claude-opus-4", "claude-sonnet-4"]
        Harness.expect(model.sort.ascending, "the first click on Model points ascending")
        Harness.expectEqual(names(), alphabetical, "the first click on Model sorts A→Z")
        Harness.expectEqual(others(), ["other-a", "other-z"], "Others sort by name too")
        model.toggleSort(.model)
        Harness.expectEqual(names(), Array(alphabetical.reversed()), "the second click on Model sorts Z→A")

        Harness.expect(!model.sort.isDefault, "a sorted column is not the default order")
        model.resetSort()
        Harness.expect(model.sort.isDefault, "reset returns to the default order")
        Harness.expectEqual(names(), defaultOrder, "reset restores configured ranks")
        Harness.expectEqual(others(), othersByUsage, "reset restores usage order")
    }

    private static func row(
        _ model: String,
        usageTokens: Int,
        input: Double?,
        output: Double?,
        cacheRead: Double?,
        group: PricingGroup = .claude,
        settingsRank: Int? = nil
    ) -> PricingRow {
        let rates = input.flatMap { input in
            output.map { ModelPricing(input: input, output: $0, cacheRead: cacheRead) }
        }
        return PricingRow(
            group: group,
            model: model,
            seenInLogs: usageTokens > 0,
            usageTokens: usageTokens,
            settingsRank: settingsRank,
            rates: rates,
            source: rates == nil ? nil : .priceBook
        )
    }
}
