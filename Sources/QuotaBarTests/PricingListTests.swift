@testable import QuotaBarApp
import QuotaBarCore
import Foundation

/// Checks the pricing list order, the search, and which row the detail side shows.
@MainActor
enum PricingListTests {
    static func run() {
        let model = PricingTableModel(costService: CostService())
        model.debugSetRows([
            Self.row("claude-opus-4", usageTokens: 900, input: 15, output: 75, cacheRead: 1.5, settingsRank: 1),
            Self.row("claude-haiku-4", usageTokens: 5_000, input: 1, output: 5, cacheRead: 0.1),
            Self.row("claude-sonnet-4", usageTokens: 0, input: 3, output: 15, cacheRead: 0.3, settingsRank: 0),
            Self.row("claude-fable-4", usageTokens: 0, input: 10, output: 50, cacheRead: 1, settingsRank: 2),
            // Seen in the logs but priced nowhere: it still ranks by the tokens it spent.
            Self.row("claude-next", usageTokens: 40, input: nil, output: nil, cacheRead: nil),
            Self.row("glm-z", usageTokens: 900, input: nil, output: nil, cacheRead: nil, group: .others),
            Self.row("other-a", usageTokens: 0, input: 1, output: 2, cacheRead: nil, group: .others),
        ])

        func names() -> [String] { model.listRows.map(\.model) }

        // Busiest first whatever the source; ties fall back to provider and name. Unused models
        // follow in their provider's configured order, Others last.
        Harness.expectEqual(
            names(),
            ["claude-haiku-4", "claude-opus-4", "glm-z", "claude-next",
             "claude-sonnet-4", "claude-fable-4", "other-a"],
            "the list puts used models first by tokens, then unused ones by configured order"
        )
        Harness.expectEqual(model.selectedRow?.model, "claude-haiku-4",
                            "with nothing picked the detail shows the busiest model")

        model.selectedRowID = model.listRows.first { $0.model == "claude-sonnet-4" }?.id
        Harness.expectEqual(model.selectedRow?.model, "claude-sonnet-4", "a picked row fills the detail")

        model.searchText = "  GLM "
        Harness.expectEqual(names(), ["glm-z"], "search ignores case and surrounding spaces")
        Harness.expectEqual(model.selectedRow?.model, "glm-z",
                            "a search that hides the picked row shows the first match instead")

        model.searchText = "claude-o"
        Harness.expectEqual(names(), ["claude-opus-4"], "search matches inside the name")

        model.searchText = "nothing"
        Harness.expect(model.listRows.isEmpty, "a search with no match empties the list")
        Harness.expect(model.selectedRow == nil, "an empty list leaves the detail empty")

        model.searchText = ""
        Harness.expectEqual(model.selectedRow?.model, "claude-sonnet-4",
                            "clearing the search brings the picked row back")
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
