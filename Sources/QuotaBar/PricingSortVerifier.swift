#if DEBUG
import QuotaBarCore
import Foundation

/// Checks column sorting, blank rates, and reset to configured model order.
@MainActor
enum PricingSortVerifier {
    static func run() -> Never {
        var failures: [String] = []

        let model = PricingEditorModel(costService: CostService())
        model.debugSetRows([
            Self.row("claude-opus-4", usageTokens: 900, input: "15", output: "75", cacheRead: "1.5", settingsRank: 1),
            Self.row("claude-haiku-4", usageTokens: 5_000, input: "1", output: "5", cacheRead: "0.1"),
            Self.row("claude-sonnet-4", usageTokens: 20, input: "3", output: "15", cacheRead: "0.3", settingsRank: 0),
            // Seen in the logs but priced nowhere, which is the row a rate sort has to place.
            Self.row("claude-next", usageTokens: 40, input: "", output: "", cacheRead: ""),
            Self.row("other-z", usageTokens: 900, input: "", output: "", cacheRead: "", group: .others),
            Self.row("other-a", usageTokens: 10, input: "", output: "", cacheRead: "", group: .others),
        ])

        func names() -> [String] { model.rows(in: .claude).map(\.model) }

        // Configured ranks precede usage; unranked rows use token totals.
        let defaultOrder = ["claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-next"]
        let othersByUsage = ["other-z", "other-a"]
        if names() != defaultOrder || model.rows(in: .others).map(\.model) != othersByUsage {
            failures.append("the pane did not use configured ranks and usage order")
        }

        // A rate column opens on the expensive end: that is the number a price table is opened for.
        model.toggleSort(.input)
        let expensiveFirst = ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-next"]
        if !model.sort.ascending, names() != expensiveFirst {
            failures.append("the first click on Input gave \(names()), expected \(expensiveFirst)")
        } else if model.sort.ascending {
            failures.append("the first click on Input pointed ascending")
        }

        // Flipped, the unpriced row still sinks: an empty rate is unknown, not zero.
        model.toggleSort(.input)
        let cheapFirst = ["claude-haiku-4", "claude-sonnet-4", "claude-opus-4", "claude-next"]
        if !model.sort.ascending || names() != cheapFirst {
            failures.append("the second click on Input gave \(names()), expected \(cheapFirst)")
        }

        model.toggleSort(.cacheRead)
        let byCacheRead = ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-next"]
        if model.sort.field != .cacheRead || names() != byCacheRead {
            failures.append("Cache r gave \(names()), expected \(byCacheRead)")
        }

        // A name column opens A→Z instead, since that is what reading a list of names wants.
        model.toggleSort(.model)
        let alphabetical = ["claude-haiku-4", "claude-next", "claude-opus-4", "claude-sonnet-4"]
        if !model.sort.ascending || names() != alphabetical
            || model.rows(in: .others).map(\.model) != ["other-a", "other-z"] {
            failures.append("the first click on Model gave \(names()), expected \(alphabetical)")
        }
        model.toggleSort(.model)
        if names() != alphabetical.reversed() {
            failures.append("the second click on Model gave \(names()), expected Z→A")
        }

        if model.sort.isDefault {
            failures.append("a sorted column still read as the default order")
        }
        model.resetSort()
        if !model.sort.isDefault || names() != defaultOrder
            || model.rows(in: .others).map(\.model) != othersByUsage {
            failures.append("reset did not restore configured ranks and usage order")
        }

        // Sorting is a view of the rows, not an edit of them: nothing to save from a click.
        if model.hasUnsavedChanges {
            failures.append("sorting the table marked the rates as edited")
        }

        VerifierReport.finish(
            failures,
            label: "pricing sort verification",
            passed: "pricing columns sorted both ways, sank blank rates, and reset to the configured default order"
        )
    }

    private static func row(
        _ model: String,
        usageTokens: Int,
        input: String,
        output: String,
        cacheRead: String,
        group: PricingGroup = .claude,
        settingsRank: Int? = nil
    ) -> PricingRow {
        PricingRow(
            provider: group == .claude ? .claude : .codex,
            group: group,
            model: model,
            seenInLogs: usageTokens > 0,
            hasDefault: !input.isEmpty,
            usageTokens: usageTokens,
            settingsRank: settingsRank,
            input: input,
            output: output,
            cacheWrite: "",
            cacheWrite1h: "",
            cacheRead: cacheRead,
            thresholdTokens: "",
            inputAbove: "",
            outputAbove: "",
            cacheWriteAbove: "",
            cacheWrite1hAbove: "",
            cacheReadAbove: ""
        )
    }
}
#endif
