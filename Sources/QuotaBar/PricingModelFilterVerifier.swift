#if DEBUG
import QuotaBarCore
import Foundation

/// Proves that the settings pane keeps the selected API models, lists every other model the local
/// logs name, counts an alias's usage under the model it names, and shows a third-party model
/// once whichever provider's logs named it.
@MainActor
enum PricingModelFilterVerifier {
    static func run() -> Never {
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
    }

    private static func verify() async -> Never {
        var failures: [String] = []
        let rateCard = RateCard(thirdParty: ThirdPartyRates(current: [
            "deepseek-flash": ModelPricing(input: 0.15, output: 0.6),
        ]))

        self.expect(
            PricingGroup.classify(model: "gpt-6-astra", provider: .codex, rateCard: rateCard) == .codex,
            "Astra was not classified as Codex",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "gpt-local-unpriced", provider: .codex, rateCard: rateCard) == .others,
            "an unpriced GPT model returned to the Codex group",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "claude-local-unpriced", provider: .claude, rateCard: rateCard) == .others,
            "an unpriced Claude model returned to the Claude group",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "claude-haiku-4-5", provider: .claude, rateCard: rateCard) == .claude,
            "the actual Haiku model id was not classified as Claude",
            failures: &failures
        )
        self.expect(
            PricingGroup.classify(model: "deepseek-flash", provider: .codex, rateCard: rateCard) == .others,
            "a models.dev model left the Others group",
            failures: &failures
        )

        let codexSettingsModels = rateCard.settingsModels(for: .codex)
        let visibleCodex = PricingModelFilterPolicy.visibleModels(
            provider: .codex,
            usage: [
                ModelUsageTotal(model: "deepseek-flash", tokens: 100),
                ModelUsageTotal(model: "gpt-local-unpriced", tokens: 100),
                ModelUsageTotal(model: "gpt-5.6", tokens: 100),
                ModelUsageTotal(model: CostPricing.unknownModel, tokens: 100),
            ],
            rateCard: rateCard
        )
        self.expectNames(
            visibleCodex,
            codexSettingsModels + ["deepseek-flash", "gpt-local-unpriced"],
            "Codex visible models",
            failures: &failures
        )

        // `gpt-5.6` is the price book's alias of `gpt-5.6-sol`: the pane shows one row for the
        // model, seen in the logs, with the alias's and the ID's usage added together. A
        // third-party model both providers' logs name is one row with both providers' usage.
        let pricing = PricingTableModel(
            costService: CostService(rateCard: rateCard),
            fixtures: PricingTableModel.PreviewFixtures(
                usage: [
                    .codex: [
                        ModelUsageTotal(model: "gpt-5.6", tokens: 100),
                        ModelUsageTotal(model: "gpt-5.6-sol", tokens: 50),
                        ModelUsageTotal(model: "deepseek-flash", tokens: 100),
                    ],
                    .claude: [ModelUsageTotal(model: "deepseek-flash", tokens: 50)],
                ],
                rateCard: rateCard
            )
        )
        await pricing.load()
        let sol = pricing.rows.first { $0.id == "Codex|gpt-5.6-sol" }
        self.expect(
            sol?.seenInLogs == true && sol?.usageTokens == 150 && sol?.source == .priceBook,
            "alias and model ID usage did not add up on one row: \(String(describing: sol?.usageTokens))",
            failures: &failures
        )
        self.expect(
            !pricing.rows.contains { $0.model == "gpt-5.6" },
            "an alias got a row of its own",
            failures: &failures
        )
        let deepseek = pricing.rows.filter { $0.model == "deepseek-flash" }
        self.expect(
            deepseek.count == 1 && deepseek.first?.usageTokens == 150
                && deepseek.first?.source == .modelsDev && deepseek.first?.input == 0.15,
            "a third-party model was not one priced row with both providers' usage: \(deepseek)",
            failures: &failures
        )

        VerifierReport.finish(
            failures,
            label: "pricing model filter verification",
            passed: "pricing model filter kept the API whitelists and listed every other model once"
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
}
#endif
