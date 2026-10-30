@testable import QuotaBarApp
import QuotaBarCore
import Foundation

/// Checks the pricing list's sections, vendors and order, the search, folding a vendor, and which
/// row the detail side shows.
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
            Self.row("gpt-a", usageTokens: 6_000, input: 1, output: 2, cacheRead: nil, group: .codex, vendor: "OpenAI"),
            Self.row("glm-z", usageTokens: 900, input: nil, output: nil, cacheRead: nil, group: .others, vendor: "Zhipu AI"),
            Self.row("kimi-a", usageTokens: 10, input: 1, output: 2, cacheRead: nil, group: .others,
                     vendor: "Moonshot AI", source: .modelsDev),
            Self.row("deepseek-a", usageTokens: 0, input: 1, output: 2, cacheRead: nil, group: .others,
                     vendor: "DeepSeek", source: .modelsDev),
            Self.row("other-a", usageTokens: 900, input: 1, output: 2, cacheRead: nil, group: .others,
                     vendor: PricingVendor.other, source: .modelsDev),
        ])

        func names() -> [String] { model.listRows.map(\.model) }

        // Each source is a block of its own, even when the other holds a busier model. A vendor
        // is ordered by its tokens, with Other last whatever it spent.
        Harness.expectEqual(
            model.listSections.map { $0.section },
            [.builtIn, .modelsDev, .unpriced],
            "sources keep a fixed order"
        )
        Harness.expectEqual(
            model.listSections.map { $0.vendors.map(\.vendor) },
            [["OpenAI", "Anthropic"], ["Moonshot AI", "DeepSeek", PricingVendor.other], ["Zhipu AI", "Anthropic"]],
            "vendors go busiest first with Other last, and a vendor can appear under two sources"
        )
        Harness.expectEqual(
            names(),
            ["gpt-a", "claude-haiku-4", "claude-opus-4", "claude-sonnet-4", "claude-fable-4",
             "kimi-a", "deepseek-a", "other-a", "glm-z", "claude-next"],
            "within a vendor, used models go first by tokens, then unused ones by configured order"
        )
        Harness.expectEqual(model.selectedRow?.model, "gpt-a",
                            "with nothing picked the detail shows the top of the list")

        model.selectedRowID = model.listRows.first { $0.model == "claude-sonnet-4" }?.id
        Harness.expectEqual(model.selectedRow?.model, "claude-sonnet-4", "a picked row fills the detail")

        model.searchText = "  GLM "
        Harness.expectEqual(names(), ["glm-z"], "search ignores case and surrounding spaces")
        Harness.expectEqual(model.selectedRow?.model, "glm-z",
                            "a search that hides the picked row shows the first match instead")

        model.searchText = ""
        let anthropic = model.listSections[0].vendors[1]
        model.toggle(anthropic)
        Harness.expect(!model.visibleRows.contains { $0.vendor == "Anthropic" && $0.section == .builtIn },
                       "a folded vendor's rows leave the arrow keys' path")
        Harness.expect(model.visibleRows.contains { $0.model == "claude-next" },
                       "folding a vendor in one source leaves it open in the others")
        Harness.expect(model.selectedRowID == nil, "folding away the picked row clears the pick")
        model.searchText = "sonnet"
        Harness.expectEqual(model.visibleRows.map(\.model), ["claude-sonnet-4"],
                            "a search reaches into a folded vendor")
        model.searchText = ""
        model.toggle(anthropic)
        Harness.expect(model.visibleRows.contains { $0.model == "claude-sonnet-4" }, "a second toggle opens it again")
        model.selectedRowID = model.listRows.first { $0.model == "claude-sonnet-4" }?.id

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
        vendor: String = "Anthropic",
        source: RateCard.Source = .priceBook,
        settingsRank: Int? = nil
    ) -> PricingRow {
        let rates = input.flatMap { input in
            output.map { ModelPricing(input: input, output: $0, cacheRead: cacheRead) }
        }
        return PricingRow(
            group: group,
            model: model,
            vendor: vendor,
            seenInLogs: usageTokens > 0,
            usageTokens: usageTokens,
            settingsRank: settingsRank,
            rates: rates,
            source: rates == nil ? nil : source
        )
    }
}
