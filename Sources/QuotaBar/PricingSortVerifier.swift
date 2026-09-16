#if DEBUG
import QuotaBarCore
import Foundation

/// Proves the pricing table's column sorting: which way a fresh click points, that a blank rate
/// never floats to the top of an ascending column, and that the header's reset control puts the
/// most-used models back in front.
@MainActor
enum PricingSortVerifier {
    static func run() -> Never {
        var failures: [String] = []

        let model = PricingEditorModel(costService: CostService())
        model.debugSetRows([
            Self.row("claude-opus-4", usageTokens: 900, input: "15", output: "75", cacheRead: "1.5"),
            Self.row("claude-haiku-4", usageTokens: 5_000, input: "1", output: "5", cacheRead: "0.1"),
            Self.row("claude-sonnet-4", usageTokens: 20, input: "3", output: "15", cacheRead: "0.3"),
            // Seen in the logs but priced nowhere, which is the row a rate sort has to place.
            Self.row("claude-next", usageTokens: 40, input: "", output: "", cacheRead: ""),
        ])

        func names() -> [String] { model.rows(in: .claude).map(\.model) }

        let byUsage = ["claude-haiku-4", "claude-opus-4", "claude-next", "claude-sonnet-4"]
        if names() != byUsage {
            failures.append("the pane opened in \(names()), expected most used first: \(byUsage)")
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
        if !model.sort.ascending || names() != alphabetical {
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
        if !model.sort.isDefault || names() != byUsage {
            failures.append("the reset control gave \(names()), expected \(byUsage)")
        }

        // Sorting is a view of the rows, not an edit of them: nothing to save from a click.
        if model.hasUnsavedChanges {
            failures.append("sorting the table marked the rates as edited")
        }

        // API whitelist rows keep their product order even when usage differs; only Others use
        // token usage for the default order.
        let whitelistModel = PricingEditorModel(costService: CostService())
        whitelistModel.debugSetRows([
            Self.row("claude-fable-5-1", usageTokens: 5, input: "10", output: "50", cacheRead: "0.25"),
            Self.row("claude-fable-5", usageTokens: 10, input: "10", output: "50", cacheRead: "1"),
            Self.row("claude-opus-5", usageTokens: 900, input: "15", output: "75", cacheRead: "1.5"),
            Self.row("claude-sonnet-5", usageTokens: 20, input: "3", output: "15", cacheRead: "0.3"),
            Self.row("claude-haiku-4-5", usageTokens: 500, input: "1", output: "5", cacheRead: "0.1"),
            Self.row("claude-3-5-haiku", usageTokens: 700, input: "0.8", output: "4", cacheRead: "0.08"),
            Self.row("gpt-5.6-sol", usageTokens: 10, input: "5", output: "25", cacheRead: "0.5", group: .codex),
            Self.row("gpt-5.6-terra", usageTokens: 900, input: "3", output: "15", cacheRead: "0.3", group: .codex),
            Self.row("gpt-5.6-luna", usageTokens: 20, input: "1", output: "5", cacheRead: "0.1", group: .codex),
            Self.row("codex-mini-latest", usageTokens: 700, input: "1.5", output: "6", cacheRead: "0.375", group: .codex),
            Self.row("other-heavy", usageTokens: 900, input: "", output: "", cacheRead: "", group: .others),
            Self.row("other-light", usageTokens: 10, input: "", output: "", cacheRead: "", group: .others),
        ])
        let expectedClaude = [
            "claude-fable-5-1", "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
            "claude-3-5-haiku",
        ]
        let expectedCodex = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "codex-mini-latest"]
        let expectedOthers = ["other-heavy", "other-light"]
        if whitelistModel.rows(in: .claude).map(\.model) != expectedClaude {
            failures.append("default Claude order changed with usage: \(whitelistModel.rows(in: .claude).map(\.model))")
        }
        if whitelistModel.rows(in: .codex).map(\.model) != expectedCodex {
            failures.append("default Codex order changed with usage: \(whitelistModel.rows(in: .codex).map(\.model))")
        }
        if whitelistModel.rows(in: .others).map(\.model) != expectedOthers {
            failures.append("default Others order changed with usage: \(whitelistModel.rows(in: .others).map(\.model))")
        }
        whitelistModel.toggleSort(.model)
        whitelistModel.resetSort()
        if whitelistModel.rows(in: .claude).map(\.model) != expectedClaude
            || whitelistModel.rows(in: .codex).map(\.model) != expectedCodex
            || whitelistModel.rows(in: .others).map(\.model) != expectedOthers {
            failures.append("reset did not restore whitelist order and Others usage order")
        }

        // Groups sort independently, so a click never drags a model out of its provider section.
        model.debugSetRows([
            Self.row("claude-opus-4", usageTokens: 10, input: "15", output: "75", cacheRead: "1.5"),
            Self.row("gpt-5", usageTokens: 10, input: "1.25", output: "10", cacheRead: "0.125", group: .codex),
        ])
        model.toggleSort(.input)
        if model.rows(in: .claude).map(\.model) != ["claude-opus-4"]
            || model.rows(in: .codex).map(\.model) != ["gpt-5"] {
            failures.append("a rate sort moved a model across provider sections")
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
        group: PricingGroup = .claude
    ) -> PricingRow {
        PricingRow(
            provider: group == .claude ? .claude : .codex,
            group: group,
            model: model,
            seenInLogs: usageTokens > 0,
            hasDefault: !input.isEmpty,
            usageTokens: usageTokens,
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
