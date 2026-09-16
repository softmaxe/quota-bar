import Foundation
import QuotaBarCore

enum AstraPricingTests {
    static func run() async {
        Self.standardRates()
        Self.fastRates()
        Self.longContextBoundary()
        Self.catalogTierFallback()
        await Self.codexScannerIntegration()
    }

    private static let standard = ModelPricing(
        input: 10,
        output: 50,
        cacheWrite: 12.5,
        cacheRead: 1,
        thresholdTokens: 272_000,
        inputAbove: 20,
        outputAbove: 75,
        cacheWriteAbove: 25,
        cacheReadAbove: 2
    )

    private static let fast = ModelPricing(
        input: 20,
        output: 100,
        cacheWrite: 25,
        cacheRead: 2,
        thresholdTokens: 272_000,
        inputAbove: 40,
        outputAbove: 150,
        cacheWriteAbove: 50,
        cacheReadAbove: 4
    )

    private static func standardRates() {
        Harness.expectEqual(
            CostPricing.pricing(for: "gpt-6-astra", provider: .codex),
            Self.standard,
            "Astra Standard rates match the official table"
        )
        Harness.expectClose(
            CostPricing.cost(
                totals: TokenTotals(
                    input: 1_000_000,
                    output: 1_000_000,
                    cacheWrite: 1_000_000,
                    cacheRead: 1_000_000
                ),
                model: "gpt-6-astra",
                provider: .codex,
                longContext: false
            ),
            73.5,
            "Astra Standard cost uses every published token bucket"
        )
    }

    private static func fastRates() {
        Harness.expectEqual(
            CostPricing.pricing(
                for: "gpt-6-astra",
                provider: .codex,
                codexServiceTier: .fast
            ),
            Self.fast,
            "Astra Fast rates are twice the applicable Standard rates"
        )
        Harness.expectClose(
            CostPricing.cost(
                totals: TokenTotals(input: 1_000_000, output: 1_000_000),
                model: "gpt-6-astra",
                provider: .codex,
                longContext: true,
                codexServiceTier: .fast
            ),
            190,
            "Astra Fast long-context cost applies both published multipliers"
        )
    }

    private static func longContextBoundary() {
        Harness.expect(
            !CostPricing.isLongContext(
                totals: TokenTotals(input: 200_000, cacheRead: 72_000),
                model: "gpt-6-astra",
                provider: .codex
            ),
            "Astra stays at Standard rates at exactly 272K input tokens"
        )
        Harness.expect(
            CostPricing.isLongContext(
                totals: TokenTotals(input: 200_000, cacheRead: 72_001),
                model: "gpt-6-astra",
                provider: .codex
            ),
            "Astra switches tiers above 272K input tokens"
        )
        Harness.expectClose(
            CostPricing.cost(
                totals: TokenTotals(
                    input: 1_000_000,
                    output: 1_000_000,
                    cacheWrite: 1_000_000,
                    cacheRead: 1_000_000
                ),
                model: "gpt-6-astra",
                provider: .codex,
                longContext: true
            ),
            122,
            "Astra long-context cost doubles input and cache and multiplies output by 1.5"
        )
    }

    private static func catalogTierFallback() {
        let incompleteCatalog = PricingOverlay(
            modelsDev: ["gpt-6-astra": ModelPricing(input: 1, output: 2, cacheRead: 0.1)]
        )
        Harness.expectEqual(
            CostPricing.pricing(
                for: "gpt-6-astra",
                provider: .codex,
                overlay: incompleteCatalog
            ),
            Self.standard,
            "an incomplete Astra catalog row falls back to the official tiered rates"
        )

        let incompleteAboveRates = ModelPricing(
            input: 11,
            output: 51,
            cacheWrite: 13,
            cacheRead: 1.1,
            thresholdTokens: 200_000,
            inputAbove: 22,
            outputAbove: 76.5
        )
        Harness.expectEqual(
            CostPricing.pricing(
                for: "gpt-6-astra",
                provider: .codex,
                overlay: PricingOverlay(modelsDev: ["gpt-6-astra": incompleteAboveRates])
            ),
            Self.standard,
            "an Astra catalog threshold without cache rates is still incomplete"
        )

        let completeCatalogRate = ModelPricing(
            input: 11,
            output: 51,
            cacheWrite: 13,
            cacheRead: 1.1,
            thresholdTokens: 300_000,
            inputAbove: 22,
            outputAbove: 76.5,
            cacheWriteAbove: 26,
            cacheReadAbove: 2.2
        )
        Harness.expectEqual(
            CostPricing.pricing(
                for: "gpt-6-astra",
                provider: .codex,
                overlay: PricingOverlay(modelsDev: ["gpt-6-astra": completeCatalogRate])
            ),
            completeCatalogRate,
            "a complete future Astra catalog row keeps catalog precedence"
        )

        let userRate = ModelPricing(input: 7, output: 8)
        Harness.expectEqual(
            CostPricing.pricing(
                for: "gpt-6-astra",
                provider: .codex,
                overlay: PricingOverlay(
                    userOverrides: ["gpt-6-astra": userRate],
                    modelsDev: ["gpt-6-astra": completeCatalogRate]
                )
            ),
            userRate,
            "an Astra user override keeps the documented highest precedence"
        )
    }

    private static func codexScannerIntegration() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-astra-pricing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let log = codexHome.appendingPathComponent("sessions/rollout-astra.jsonl")
        do {
            try FileManager.default.createDirectory(
                at: log.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date())
            let lines = [
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"default"}}}"#,
                #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-6-astra"}}"#,
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":272000,"cached_input_tokens":72000,"cache_write_input_tokens":0,"output_tokens":1000}}}}"#,
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}"#,
                #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-6-astra"}}"#,
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":272001,"cached_input_tokens":72000,"cache_write_input_tokens":1,"output_tokens":1000}}}}"#,
            ]
            try (lines.joined(separator: "\n") + "\n")
                .write(to: log, atomically: true, encoding: .utf8)
        } catch {
            Harness.expect(false, "Astra scanner fixture setup threw: \(error)")
            return
        }

        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: [
                "CODEX_HOME": codexHome.path,
                "HOME": root.path,
                "XDG_DATA_HOME": root.appendingPathComponent("xdg").path,
                "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path,
            ],
            pricingOverlay: PricingOverlay()
        )
        let snapshot = await service.refresh(.codex)
        let standardKey = ModelUsageKey(source: .codex, model: "gpt-6-astra")
        let fastKey = ModelUsageKey(source: .codex, model: "gpt-6-astra", isFast: true)

        Harness.expectEqual(snapshot?.windowTokens, 546_001, "Astra scanner keeps both turns")
        Harness.expectEqual(snapshot?.days.first?.byModel.count, 2, "Astra scanner separates Standard and Fast")
        Harness.expectEqual(
            snapshot?.days.first?.byModel[standardKey]?.tokens,
            TokenTotals(input: 200_000, output: 1_000, cacheRead: 72_000),
            "Astra vendor-prefixed model id normalizes into the Standard row"
        )
        Harness.expectEqual(
            snapshot?.days.first?.byModel[fastKey]?.tokens,
            TokenTotals(input: 200_000, output: 1_000, cacheWrite: 1, cacheRead: 72_000),
            "Astra priority usage stays in the Fast row"
        )
        Harness.expectClose(
            snapshot?.days.first?.byModel[standardKey]?.costUSD,
            2.122,
            "Astra scanner keeps the 272K request on Standard rates"
        )
        Harness.expectClose(
            snapshot?.days.first?.byModel[fastKey]?.costUSD,
            8.43805,
            "Astra scanner applies Fast long-context rates above 272K"
        )
    }
}
