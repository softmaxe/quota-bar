import Foundation
import QuotaBarCore

/// The rate card: the price book with the third-party rates beside it, and the one place a rate
/// is looked up.
enum RateCardTests {
    static func run() {
        guard let book = Self.book() else { return }
        Self.modelNames(book)
        Self.datedRates(book)
        Self.thirdParty(book)
        Self.fast(book)
        Self.longContextTier(book)
        Self.unpricedUsage(book)
        Self.settingsModels(book)
    }

    private static func book() -> PriceBook? {
        do {
            return try PriceBook(data: Data("""
                {
                  "schemaVersion": 1,
                  "providers": {
                    "codex": {
                      "source": "https://example.com", "checkedAt": "2026-09-01",
                      "models": [
                        {
                          "id": "ox-dated",
                          "aliases": ["ox"],
                          "showInSettings": true,
                          "periods": [
                            { "rates": { "input": 4, "output": 20, "thresholdTokens": 100, "inputAbove": 8 }, "fastMultiplier": 2 },
                            { "from": "2026-11-22", "rates": { "input": 5, "output": 30 } }
                          ]
                        },
                        { "id": "ox-hidden", "periods": [ { "rates": { "input": 1, "output": 1 } } ] }
                      ]
                    },
                    "claude": {
                      "source": "https://example.com", "checkedAt": "2026-09-01",
                      "models": [
                        { "id": "claude-fixture-5", "showInSettings": true, "periods": [ { "rates": { "input": 3, "output": 15 } } ] },
                        { "id": "claude-fixture-fast", "periods": [ { "rates": { "input": 4, "output": 20, "cacheRead": 0.2 }, "fastMultiplier": 2 } ] }
                      ]
                    }
                  }
                }
                """.utf8))
        } catch {
            Harness.expect(false, "rate card fixture book threw: \(error)")
            return nil
        }
    }

    private static let million = TokenTotals(input: 1_000_000)

    /// Names resolve against the card's own book, not the one the app ships.
    private static func modelNames(_ book: PriceBook) {
        let card = RateCard(book: book)
        Harness.expectEqual(card.modelID(for: "OpenAI/ox-20260101", provider: .codex), "ox-dated", "an alias resolves through the card's book")
        Harness.expectEqual(card.modelID(for: "anthropic.claude-fixture-5-v1:0", provider: .claude), "claude-fixture-5", "a Claude name loses its vendor decorations")
        Harness.expectEqual(card.modelID(for: "ox-dated", provider: .codex), "ox-dated", "a model id is already its own name")
        Harness.expect(
            card.rates(for: "ox", provider: .codex, day: "2026-01-01") == nil,
            "rates are looked up by model id, the name usage is stored under"
        )
    }

    private static func datedRates(_ book: PriceBook) {
        let card = RateCard(book: book)
        Harness.expectEqual(
            card.cost(of: Self.million, model: "ox-dated", provider: .codex, day: "2020-01-01", longContext: false),
            4,
            "the opening period covers every day before the next one"
        )
        Harness.expectEqual(
            card.cost(of: Self.million, model: "ox-dated", provider: .codex, day: "2026-11-21", longContext: false),
            4,
            "the day before a new period keeps the old rates"
        )
        Harness.expectEqual(
            card.cost(of: Self.million, model: "ox-dated", provider: .codex, day: "2026-11-22", longContext: false),
            5,
            "a period applies from its first day"
        )
        Harness.expect(
            card.rates(for: "ox-dated", provider: .claude, day: "2026-11-22") == nil,
            "models are looked up within their own provider"
        )
    }

    private static func thirdParty(_ book: PriceBook) {
        let card = RateCard(book: book, thirdParty: ThirdPartyRates(
            models: [
                "ox-dated": [.init(from: nil, rates: ModelPricing(input: 1, output: 1))],
                "glm-dated": [
                    .init(from: nil, rates: ModelPricing(input: 1, output: 2)),
                    .init(from: "2026-11-22", rates: ModelPricing(input: 3, output: 4)),
                ],
                "claude-reseller": [.init(from: nil, rates: ModelPricing(input: 1, output: 1))],
            ],
            fetchedAt: nil
        ))
        Harness.expectEqual(
            card.cost(of: Self.million, model: "ox-dated", provider: .codex, day: "2026-12-01", longContext: false),
            5,
            "the book prices a model it lists even when models.dev lists it too"
        )
        Harness.expectEqual(card.source(for: "ox-dated", provider: .codex), .priceBook, "a book model is the book's")
        Harness.expectEqual(
            card.cost(of: Self.million, model: "glm-dated", provider: .codex, day: "2026-11-21", longContext: false),
            1,
            "models.dev prices a model the book does not list"
        )
        Harness.expectEqual(
            card.cost(of: Self.million, model: "glm-dated", provider: .claude, day: "2026-11-22", longContext: false),
            3,
            "a third-party rate change opens a period on the day it was seen, for either provider"
        )
        Harness.expectEqual(card.source(for: "glm-dated", provider: .claude), .modelsDev, "a third-party model is models.dev's")
        Harness.expectEqual(
            card.rates(for: "openrouter/z-ai/GLM-DATED", provider: .claude, day: "2026-11-22")?.input,
            3,
            "a routed name finds its third-party rates"
        )
        Harness.expect(
            card.rates(for: "claude-reseller", provider: .claude, day: "2026-11-22") == nil
                && card.source(for: "claude-reseller", provider: .claude) == nil,
            "models.dev never prices a Claude or OpenAI model"
        )
        Harness.expect(
            card.rates(for: "glm-dated", provider: .codex, day: "2026-11-22", fast: true) == nil,
            "models.dev has no Fast tier, so Fast third-party usage is unpriced"
        )
        Harness.expect(
            card.source(for: "ox-unlisted", provider: .codex) == nil,
            "a model neither source lists has no source"
        )
    }

    /// Fast is a multiple of the book's Standard rates.
    private static func fast(_ book: PriceBook) {
        let card = RateCard(book: book)
        Harness.expectEqual(
            card.rates(for: "ox-dated", provider: .codex, day: "2026-11-21", fast: true),
            ModelPricing(input: 8, output: 40, thresholdTokens: 100, inputAbove: 16),
            "Fast multiplies the book's rates"
        )
        Harness.expect(
            card.rates(for: "ox-dated", provider: .codex, day: "2026-11-22", fast: true) == nil,
            "a period without a Fast multiplier leaves Fast unpriced"
        )

        // Claude Fast mode follows the same rule, with prompt-caching rates scaled alongside.
        Harness.expectEqual(
            card.rates(for: "claude-fixture-fast", provider: .claude, day: "2026-11-21", fast: true),
            ModelPricing(input: 8, output: 40, cacheRead: 0.4),
            "Claude Fast multiplies the book's rates"
        )
        Harness.expect(
            card.rates(for: "claude-fixture-5", provider: .claude, day: "2026-11-21", fast: true) == nil,
            "a Claude model without a Fast multiplier leaves Fast unpriced"
        )
    }

    private static func longContextTier(_ book: PriceBook) {
        let card = RateCard(book: book)
        let request = TokenTotals(input: 60, cacheRead: 41)
        Harness.expect(
            card.isLongContext(request, model: "ox-dated", provider: .codex, day: "2026-11-21"),
            "input and cache tokens together cross the threshold"
        )
        Harness.expect(
            !card.isLongContext(TokenTotals(input: 100, output: 500), model: "ox-dated", provider: .codex, day: "2026-11-21"),
            "output tokens do not count toward the threshold"
        )
        Harness.expect(
            !card.isLongContext(request, model: "ox-dated", provider: .codex, day: "2026-11-22"),
            "a period without a threshold has no long-context tier"
        )
        let thirdParty = RateCard(book: book, thirdParty: ThirdPartyRates(current: [
            "glm-tiered": ModelPricing(input: 1, output: 1, thresholdTokens: 200_000, inputAbove: 3),
        ]))
        Harness.expect(
            thirdParty.isLongContext(TokenTotals(input: 150_000, cacheRead: 50_001), model: "glm-tiered", provider: .codex, day: "2026-11-22")
                && !thirdParty.isLongContext(TokenTotals(input: 200_000), model: "glm-tiered", provider: .codex, day: "2026-11-22"),
            "a third-party request is in the tier above 200K tokens"
        )
        Harness.expect(
            RateCard(book: book).isLongContext(TokenTotals(input: 200_001), model: "glm-not-fetched", provider: .claude, day: "2026-11-22"),
            "a third-party request is classified before its rates are downloaded"
        )
        Harness.expect(
            !thirdParty.isLongContext(TokenTotals(input: 200_001), model: "glm-tiered", provider: .codex, day: "2026-11-22", fast: true)
                && !RateCard(book: book).isLongContext(TokenTotals(input: 200_001), model: "claude-unlisted", provider: .claude, day: "2026-11-22"),
            "Fast usage and unlisted Claude or OpenAI models are not classified against the third-party threshold"
        )
        Harness.expectEqual(
            thirdParty.cost(of: Self.million, model: "glm-tiered", provider: .codex, day: "2026-11-22", longContext: true),
            3,
            "the long-context tier bills the third-party rates above the threshold"
        )

        // A one-hour cache write bills at its own rate when one is stated.
        let hourly = RateCard(book: book, thirdParty: ThirdPartyRates(current: [
            "glm-hourly": ModelPricing(
                input: 1, output: 1, cacheWrite1h: 3.5,
                thresholdTokens: 50, inputAbove: 3, cacheWrite1hAbove: 7
            ),
        ]))
        let oneHourWrite = TokenTotals(cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)
        Harness.expectEqual(
            hourly.cost(of: oneHourWrite, model: "glm-hourly", provider: .codex, day: "2026-11-22", longContext: false),
            3.5,
            "a stated one-hour rate is what bills"
        )
        Harness.expectEqual(
            hourly.cost(of: oneHourWrite, model: "glm-hourly", provider: .codex, day: "2026-11-22", longContext: true),
            7,
            "the long-context one-hour rate applies above the threshold"
        )
    }

    private static func unpricedUsage(_ book: PriceBook) {
        let card = RateCard(book: book)
        Harness.expect(
            card.cost(of: Self.million, model: "ox-unlisted", provider: .codex, day: "2026-11-22", longContext: false) == nil,
            "a model with no rate on its day is unpriced"
        )
        Harness.expect(
            card.cost(of: Self.million, model: CostPricing.unknownModel, provider: .codex, day: "2026-11-22", longContext: false) == nil,
            "the unknown model is never priced"
        )
    }

    private static func settingsModels(_ book: PriceBook) {
        let card = RateCard(book: book)
        Harness.expectEqual(card.settingsModels(for: .codex), ["ox-dated"], "only models marked for settings are listed")
        Harness.expectEqual(card.settingsModels(for: .claude), ["claude-fixture-5"], "each provider lists its own")
    }
}
