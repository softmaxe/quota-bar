import Foundation
import QuotaBarCore

/// Third-party rates: how models.dev is read into one price per model, how fetches build dated
/// periods in the local cache, and how often the service downloads.
enum ThirdPartyRatesTests {
    static func run() async {
        Self.catalog()
        Self.merging()
        Self.regionSuffixes()
        Self.cacheRoundTrip()
        await Self.downloads()
    }

    private static let catalogJSON = """
        {
          "deepseek": { "id": "deepseek", "models": {
            "deepseek-flash": { "id": "deepseek-flash", "canonical_model_id": "deepseek/deepseek-v4.1-flash",
                                "cost": { "input": 0.15, "output": 0.6, "cache_read": 0.003 } }
          } },
          "reseller-a": { "id": "reseller-a", "models": {
            "deepseek/deepseek-v4.1-flash": { "canonical_model_id": "deepseek/deepseek-v4.1-flash",
                                              "cost": { "input": 0.05, "output": 0.1 } },
            "kimi-k3": { "canonical_model_id": "moonshotai/kimi-k3", "cost": { "input": 2, "output": 10 } },
            "free-model": { "cost": { "input": 0, "output": 0 } },
            "gpt-oss-20b": { "canonical_model_id": "openai/gpt-oss-20b", "cost": { "input": 0.1, "output": 0.5 } },
            "claude-opus-5": { "cost": { "input": 1, "output": 2 } },
            "openai-o3": { "cost": { "input": 2, "output": 8 } },
            "anthropic--claude-3-opus": { "cost": { "input": 15, "output": 75 } },
            "us.anthropic.claude-opus-4-7": { "cost": { "input": 5, "output": 25 } },
            "unpriced": { "id": "unpriced" }
          } },
          "reseller-b": { "id": "reseller-b", "models": {
            "kimi-k3": { "canonical_model_id": "moonshotai/kimi-k3", "cost": { "input": 3, "output": 15 } },
            "Kimi-K3:TEE": { "canonical_model_id": "moonshotai/kimi-k3", "cost": { "input": 9, "output": 9 } }
          } },
          "reseller-c": { "id": "reseller-c", "models": {
            "moonshotai/kimi-k3": { "canonical_model_id": "moonshotai/kimi-k3", "cost": { "input": 2.5, "output": 12 } },
            "gemini-9-pro": { "cost": { "input": 2, "output": 12, "cache_read": 0.2,
                                        "context_over_200k": { "input": 4, "output": 18, "cache_read": 0.4 } } }
          } }
        }
        """

    private static func catalog() {
        let rates: [String: ModelPricing]
        do {
            rates = try ModelsDevCatalog.rates(from: Data(Self.catalogJSON.utf8))
        } catch {
            Harness.expect(false, "the catalog fixture threw: \(error)")
            return
        }
        Harness.expectEqual(
            rates["deepseek-v4.1-flash"],
            ModelPricing(input: 0.15, output: 0.6, cacheRead: 0.003),
            "the maker's own listing wins, even under the maker's short name"
        )
        Harness.expectEqual(rates["deepseek-flash"]?.input, 0.15, "the maker's short name is priced too")
        Harness.expectEqual(
            rates["kimi-k3"],
            ModelPricing(input: 2.5, output: 12),
            "without the maker's listing the middle reseller price is used"
        )
        Harness.expect(rates["free-model"] == nil, "a model listed only for free is left unpriced")
        Harness.expect(rates["gpt-oss-20b"] == nil, "an OpenAI model is left to the price book")
        Harness.expect(rates["claude-opus-5"] == nil, "a Claude model is left to the price book")
        Harness.expect(
            rates["openai-o3"] == nil && rates["anthropic--claude-3-opus"] == nil
                && rates["us.anthropic.claude-opus-4-7"] == nil,
            "a reseller's spelling of a Claude or OpenAI model is left to the price book"
        )
        Harness.expect(
            ThirdPartyRates.isThirdParty("glm-5.3") && ThirdPartyRates.isThirdParty("ollama-qwen3")
                && !ThirdPartyRates.isThirdParty("azure/gpt-5.5") && !ThirdPartyRates.isThirdParty("o4-mini"),
            "only Claude and OpenAI names are refused"
        )
        Harness.expect(rates["unpriced"] == nil, "a listing without a cost is skipped")
        Harness.expectEqual(rates["kimi-k3:tee"]?.input, 9, "a tagged offer keeps its own price")
        Harness.expectEqual(
            rates["gemini-9-pro"],
            ModelPricing(input: 2, output: 12, cacheRead: 0.2, thresholdTokens: 200_000,
                         inputAbove: 4, outputAbove: 18, cacheReadAbove: 0.4),
            "rates above 200K tokens become the long-context tier"
        )
        Harness.expect(
            (try? ModelsDevCatalog.rates(from: Data("[]".utf8))) == nil,
            "something other than a provider catalog is refused"
        )
    }

    private static func merging() {
        let first = ThirdPartyRates.empty.merging(
            ["GLM-5.3": ModelPricing(input: 1, output: 4)],
            on: "2026-10-01",
            at: Date(timeIntervalSince1970: 1)
        )
        Harness.expectEqual(
            first.models["glm-5.3"],
            [.init(from: nil, rates: ModelPricing(input: 1, output: 4))],
            "a model's first rates cover every earlier day"
        )
        let unchanged = first.merging(["glm-5.3": ModelPricing(input: 1, output: 4)], on: "2026-10-05", at: Date())
        Harness.expectEqual(unchanged.models["glm-5.3"]?.count, 1, "unchanged rates open no period")

        let changed = unchanged.merging(["glm-5.3": ModelPricing(input: 2, output: 5)], on: "2026-10-09", at: Date())
        Harness.expectEqual(
            changed.rates(for: "glm-5.3", day: "2026-10-08")?.input,
            1,
            "days before a change keep the rates they had"
        )
        Harness.expectEqual(changed.rates(for: "glm-5.3", day: "2026-10-09")?.input, 2, "the change applies from its day")

        let sameDay = changed.merging(["glm-5.3": ModelPricing(input: 3, output: 6)], on: "2026-10-09", at: Date())
        Harness.expectEqual(sameDay.models["glm-5.3"]?.count, 2, "a second change on one day replaces the first")
        Harness.expectEqual(sameDay.rates(for: "glm-5.3", day: "2026-10-09")?.input, 3, "the day's last rates apply")

        let dropped = sameDay.merging(["kimi-k3": ModelPricing(input: 2, output: 10)], on: "2026-10-10", at: Date())
        Harness.expectEqual(
            dropped.rates(for: "glm-5.3", day: "2026-10-10")?.input,
            3,
            "a model models.dev stopped listing keeps its last rates"
        )
    }

    private static func regionSuffixes() {
        let rates = ThirdPartyRates(current: [
            "deepseek-v4.1-flash": ModelPricing(input: 0.15, output: 0.6),
            "glm-5.3": ModelPricing(input: 1, output: 4),
            "glm-5.3-eu": ModelPricing(input: 1.5, output: 5),
        ])
        Harness.expectEqual(
            rates.rates(for: "deepseek-v4.1-flash-sg", day: "2026-10-27")?.input,
            0.15,
            "a region suffix is priced as the model it decorates"
        )
        Harness.expect(
            rates.prices("openrouter/DeepSeek-V4.1-Flash@US") && rates.prices("glm-5.3_cn"),
            "region tags are recognised after a path, in any case, and after any separator"
        )
        Harness.expectEqual(
            rates.rates(for: "glm-5.3-eu", day: "2026-10-27")?.input,
            1.5,
            "a listing under the regional name keeps its own price"
        )
        Harness.expect(
            !rates.prices("deepseek-v4.1-flash-fast") && !rates.prices("deepseek-v4.1-flash-sg-fast"),
            "only a trailing region tag falls back"
        )
        Harness.expect(!rates.prices("sg"), "a bare region tag is not a model")
        Harness.expect(
            !ThirdPartyRates(current: ["gpt-5.5": ModelPricing(input: 1, output: 2)]).prices("gpt-5.5-us"),
            "a regional OpenAI name is still left to the price book"
        )
    }

    private static func cacheRoundTrip() {
        let root = Self.temporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelsDev = ModelsDevPricing(
            cacheURL: root.appendingPathComponent("rates.json"),
            isEnabled: { true }
        )
        Harness.expectEqual(modelsDev.cached(), .empty, "a missing cache holds nothing")

        let rates = ThirdPartyRates(
            models: [
                "glm-5.3": [
                    .init(from: nil, rates: ModelPricing(input: 1, output: 4, cacheRead: 0.2)),
                    .init(from: "2026-10-09", rates: ModelPricing(
                        input: 2, output: 5, thresholdTokens: 200_000, inputAbove: 4, outputAbove: 10
                    )),
                ],
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        do {
            try modelsDev.save(rates)
        } catch {
            Harness.expect(false, "saving the cache threw: \(error)")
        }
        Harness.expectEqual(modelsDev.cached(), rates, "the cache reads back what was saved")

        let disabled = ModelsDevPricing(cacheURL: modelsDev.cacheURL, isEnabled: { false })
        Harness.expectEqual(disabled.rates(), .empty, "nothing is priced from the cache while the setting is off")
        Harness.expectEqual(disabled.cached(), rates, "turning the setting off keeps the cache")
    }

    private static func downloads() async {
        let root = Self.temporaryDirectory("downloads")
        defer { try? FileManager.default.removeItem(at: root) }

        final class Downloads: @unchecked Sendable {
            var count = 0
            var fails = false
        }
        let downloads = Downloads()
        let catalog = Data(Self.catalogJSON.utf8)
        let modelsDev = ModelsDevPricing(
            cacheURL: root.appendingPathComponent("rates.json"),
            isEnabled: { true },
            download: {
                downloads.count += 1
                if downloads.fails { throw URLError(.notConnectedToInternet) }
                return catalog
            }
        )
        let service = CostService(databaseURL: root.appendingPathComponent("usage.sqlite"), modelsDev: modelsDev)
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        Harness.expect(await service.updateThirdPartyRates(now: start), "an empty cache is downloaded")
        Harness.expectEqual(modelsDev.cached().rates(for: "kimi-k3", day: "2030-01-01")?.input, 2.5, "the download reaches the cache")
        Harness.expect(
            !(await service.updateThirdPartyRates(now: start.addingTimeInterval(23 * 3_600))),
            "a cache less than a day old is not downloaded again"
        )
        Harness.expectEqual(downloads.count, 1, "nothing was downloaded within the day")

        downloads.fails = true
        let nextDay = start.addingTimeInterval(25 * 3_600)
        Harness.expect(!(await service.updateThirdPartyRates(now: nextDay)), "a failed download changes nothing")
        Harness.expect(
            !(await service.updateThirdPartyRates(now: nextDay.addingTimeInterval(30 * 60))),
            "a failed download is not retried within the hour"
        )
        Harness.expectEqual(downloads.count, 2, "the failure was tried once")
        Harness.expectEqual(modelsDev.cached().fetchedAt, start, "a failed download keeps the cache")

        downloads.fails = false
        Harness.expect(
            await service.updateThirdPartyRates(now: nextDay.addingTimeInterval(61 * 60)),
            "a failed download is retried after an hour"
        )

        let off = CostService(
            databaseURL: root.appendingPathComponent("off.sqlite"),
            modelsDev: ModelsDevPricing(cacheURL: root.appendingPathComponent("off.json"), isEnabled: { false }, download: {
                downloads.count += 1
                return catalog
            })
        )
        let before = downloads.count
        Harness.expect(!(await off.updateThirdPartyRates(now: start)), "nothing is downloaded while the setting is off")
        Harness.expectEqual(downloads.count, before, "the setting being off makes no request")
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-third-party-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
