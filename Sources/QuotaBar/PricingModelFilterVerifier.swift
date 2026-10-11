#if DEBUG
import QuotaBarCore
import Foundation

/// Proves that the settings pane keeps the selected API models and only shows used, unpriced
/// models from the local logs, with an alias's usage counted under the model it names.
@MainActor
enum PricingModelFilterVerifier {
    static func run() -> Never {
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
    }

    private static func verify() async -> Never {
        var failures: [String] = []
        let bundled = RateCard()

        let codexSettingsModels = bundled.settingsModels(for: .codex)
        let claudeSettingsModels = bundled.settingsModels(for: .claude)
        self.expect(
            PricingGroup.classify(model: "gpt-6-astra", rateCard: bundled) == .codex,
            "Astra was not classified as Codex",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "gpt-local-unpriced", rateCard: bundled) == .others,
            "an unpriced GPT model returned to the Codex group",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "claude-local-unpriced", rateCard: bundled) == .others,
            "an unpriced Claude model returned to the Claude group",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "claude-haiku-4-5", rateCard: bundled) == .claude,
            "the actual Haiku model id was not classified as Claude",
            failures: &failures
        )

        let rateCard = RateCard(
            overrides: [
                "gpt-override-priced": ModelPricing(input: 7, output: 8),
                "gpt-override-only": ModelPricing(input: 9, output: 10),
                "claude-override-priced": ModelPricing(input: 7, output: 8),
                "claude-override-only": ModelPricing(input: 9, output: 10),
            ]
        )

        let codexUsage = [
            ModelUsageTotal(model: "gpt-5.5", tokens: 100),
            ModelUsageTotal(model: "gpt-override-priced", tokens: 100),
            ModelUsageTotal(model: "gpt-local-unpriced", tokens: 100),
            ModelUsageTotal(model: "gpt-5.6", tokens: 100),
            ModelUsageTotal(model: CostPricing.unknownModel, tokens: 100),
        ]
        let visibleCodex = PricingModelFilterPolicy.visibleModels(
            provider: .codex,
            usage: codexUsage,
            rateCard: rateCard
        )
        self.expectNames(
            visibleCodex,
            codexSettingsModels + ["gpt-local-unpriced"],
            "Codex visible models",
            failures: &failures
        )

        let claudeUsage = [
            ModelUsageTotal(model: "claude-opus-4", tokens: 100),
            ModelUsageTotal(model: "claude-override-priced", tokens: 100),
            ModelUsageTotal(model: "claude-local-unpriced", tokens: 100),
            ModelUsageTotal(model: "claude-haiku-4-5-20251001", tokens: 100),
            ModelUsageTotal(model: CostPricing.unknownModel, tokens: 100),
        ]
        let visibleClaude = PricingModelFilterPolicy.visibleModels(
            provider: .claude,
            usage: claudeUsage,
            rateCard: rateCard
        )
        self.expectNames(
            visibleClaude,
            claudeSettingsModels + ["claude-local-unpriced"],
            "Claude visible models",
            failures: &failures
        )

        let hiddenOverride = ModelPricing(input: 11, output: 12)
        let visibleEdit = Self.row(
            provider: .codex,
            group: .codex,
            model: "gpt-5.6-sol",
            input: "9",
            output: "10"
        )
        let clearedVisibleOverride = Self.row(
            provider: .codex,
            group: .codex,
            model: "gpt-5.6-terra",
            input: "",
            output: ""
        )
        let resetVisibleOverride = Self.row(
            provider: .codex,
            group: .others,
            model: "custom-model",
            input: "1",
            output: "2"
        )
        // An unpriced Others row becomes hidden after this edit, so its new override must survive
        // the next save even though that next save cannot include the row.
        let newlyPricedOthers = Self.row(
            provider: .codex,
            group: .others,
            model: "gpt-local-unpriced",
            input: "13",
            output: "14"
        )
        let assignedOthers = PricingEditorModel.mergedUserOverrides(
            existing: [:],
            rows: [newlyPricedOthers],
            defaults: [:]
        )
        var existingOverrides = assignedOthers
        existingOverrides["gpt-hidden-priced"] = hiddenOverride
        existingOverrides["gpt-5.6-sol"] = ModelPricing(input: 4, output: 20)
        existingOverrides["gpt-5.6-terra"] = ModelPricing(input: 2, output: 12)
        existingOverrides["custom-model"] = ModelPricing(input: 9, output: 9)
        let merged = PricingEditorModel.mergedUserOverrides(
            existing: existingOverrides,
            rows: [visibleEdit, clearedVisibleOverride, resetVisibleOverride],
            defaults: [
                "codex|custom-model": ModelPricing(input: 1, output: 2),
            ]
        )
        self.expect(
            merged["gpt-hidden-priced"] == hiddenOverride,
            "saving a visible row dropped a hidden user override",
            failures: &failures
        )
        self.expect(
            merged["gpt-local-unpriced"]?.input == 13,
            "an override created for a newly priced Others row was dropped later",
            failures: &failures
        )
        self.expect(
            merged["gpt-5.6-sol"]?.input == 9,
            "a visible edit did not update its user override",
            failures: &failures
        )
        self.expect(
            merged["gpt-5.6-terra"] == nil && merged["custom-model"] == nil,
            "clearing or resetting a visible row did not remove its override",
            failures: &failures
        )

        // `gpt-5.6` is the price book's alias of `gpt-5.6-sol`: the pane shows one row for the
        // model, seen in the logs, with the alias's and the ID's usage added together.
        let pricing = PricingEditorModel(
            costService: CostService(rateCard: bundled),
            fixtures: PricingEditorModel.PreviewFixtures(
                usage: [.codex: [
                    ModelUsageTotal(model: "gpt-5.6", tokens: 100),
                    ModelUsageTotal(model: "gpt-5.6-sol", tokens: 50),
                ]],
                rateCard: bundled
            )
        )
        await pricing.load()
        let sol = pricing.rows.first { $0.id == "codex|gpt-5.6-sol" }
        self.expect(
            sol?.seenInLogs == true && sol?.usageTokens == 150,
            "alias and model ID usage did not add up on one row: \(String(describing: sol?.usageTokens))",
            failures: &failures
        )
        self.expect(
            !pricing.rows.contains { $0.model == "gpt-5.6" },
            "an alias got a row of its own",
            failures: &failures
        )

        VerifierReport.finish(
            failures,
            label: "pricing model filter verification",
            passed: "pricing model filter kept the API whitelists and used unpriced models only"
        )
    }

    private static func expect(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    private static func expectNames(
        _ actual: [String],
        _ expected: [String],
        _ message: String,
        failures: inout [String]
    ) {
        if actual != expected {
            failures.append("\(message): got \(actual), expected \(expected)")
        }
    }

    private static func row(
        provider: Provider,
        group: PricingGroup,
        model: String,
        input: String,
        output: String
    ) -> PricingRow {
        PricingRow(
            provider: provider,
            group: group,
            model: model,
            seenInLogs: true,
            hasDefault: false,
            usageTokens: 100,
            input: input,
            output: output,
            cacheWrite: "",
            cacheWrite1h: "",
            cacheRead: "",
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
