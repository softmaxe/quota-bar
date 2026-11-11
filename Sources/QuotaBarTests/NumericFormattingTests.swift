import Foundation
import QuotaBarCore
@testable import QuotaBarApp

/// Extreme numeric inputs must remain unpriced or render without narrowing to Int.
enum NumericFormattingTests {
    static func run() {
        Self.pricing()
        Self.credits()
        Self.formatting()
    }

    private static func pricing() {
        let normal = ModelPricing(input: 3, output: 15)
        Harness.expectClose(normal.cost(for: TokenTotals(input: 1_000_000), longContext: false), 3, "ordinary pricing")
        Harness.expectClose(normal.scaled(by: 2)?.input, 6, "ordinary scaled pricing")
        let huge = ModelPricing(input: 1e300, output: 1e300)
        Harness.expect(huge.cost(for: TokenTotals(input: 1_000_000_000), longContext: false)?.isFinite == true,
                       "a representable large cost survives intermediate multiplication")
        Harness.expectEqual(huge.cost(for: TokenTotals(input: Int.max), longContext: false), nil,
                            "an overflowing final cost stays unpriced")
        Harness.expectEqual(huge.scaled(by: 1e100), nil, "overflowing Fast rates stay unpriced")
        Harness.expectEqual(normal.scaled(by: .infinity), nil, "nonfinite multiplier stays unpriced")
        Harness.expectThrows("overflowing derived one-hour rate is rejected") {
            _ = try ModelPricing(rates: ["input": Double.greatestFiniteMagnitude, "output": 1])
        }
        Harness.expectThrows("overflowing long-context one-hour rate is rejected") {
            _ = try ModelPricing(rates: ["input": 1, "output": 1, "thresholdTokens": 200_000,
                                        "inputAbove": Double.greatestFiniteMagnitude])
        }
        do {
            let explicit = try ModelPricing(rates: ["input": Double.greatestFiniteMagnitude,
                                                   "output": 1, "cacheWrite1h": 1])
            Harness.expect(explicit.cost(for: TokenTotals(input: 1), longContext: false)?.isFinite == true,
                           "explicit cache pricing permits a representable extreme input rate")
        } catch {
            Harness.expect(false, "valid extreme explicit rates threw: \(error)")
        }
        let card = RateCard(thirdParty: ThirdPartyRates(models: [
            "huge-fixture": [.init(from: nil, rates: huge)],
        ], fetchedAt: nil))
        Harness.expectEqual(card.cost(of: TokenTotals(input: Int.max), model: "huge-fixture",
                                     provider: .codex, day: "2026-11-01", longContext: false), nil,
                            "rate card preserves the unpriced overflow result")
        Harness.expect(card.isLongContext(TokenTotals(input: Int.max, cacheRead: 1),
                                          model: "huge-fixture", provider: .codex, day: "2026-11-01"),
                       "long-context classification avoids overflowing the request sum")
        for invalid in [Double.infinity, -.infinity, .nan, -1] {
            Harness.expectEqual(ModelPricing(input: invalid, output: 1)
                .cost(for: TokenTotals(input: 1), longContext: false), nil, "invalid direct rates stay unpriced")
        }
    }

    private static func credits() {
        for invalid in [Double.infinity, -.infinity, .nan, -1] {
            let credits = CreditsSnapshot(hasCredits: true, unlimited: false, balance: invalid)
            Harness.expectEqual(credits.balance, nil, "invalid model balance is absent")
            Harness.expect(!credits.hasSpendableBalance, "invalid balance is not spendable")
        }
        for raw in ["inf", "-inf", "nan", "-1", "1e309"] {
            let json = Data("{\"has_credits\":true,\"balance\":\"\(raw)\"}".utf8)
            let credits = try? JSONDecoder().decode(CodexUsageResponse.Credits.self, from: json)
            Harness.expect(credits != nil && credits?.balance == nil, "invalid string balance is absent: \(raw)")
        }
        for raw in ["42.5", "1e100"] {
            let json = Data("{\"has_credits\":true,\"balance\":\"\(raw)\"}".utf8)
            let credits = try? JSONDecoder().decode(CodexUsageResponse.Credits.self, from: json)
            Harness.expectEqual(credits?.balance, Double(raw), "finite credit balance is preserved")
        }
        Harness.expect(CreditsSnapshot(hasCredits: true, unlimited: false, balance: 1e100).hasSpendableBalance,
                       "large finite credit balances remain spendable")
    }

    private static func formatting() {
        Harness.expectEqual(Formatters.cost(12.5), "$12.50", "ordinary currency formatting")
        Harness.expectEqual(Formatters.tokens(123), "123", "ordinary token formatting")
        Harness.expectEqual(Formatters.tokens(999_600), "1M", "thousands roll over to millions")
        Harness.expectEqual(Formatters.tokens(999_700_000), "1.0B", "millions roll over to billions")
        Harness.expectEqual(Formatters.tokens(Double(Int.max)), Formatters.tokens(Int.max),
                            "chart token conversion preserves the upper integer boundary")
        for value in [Double(Int.max), 1e100, Double.greatestFiniteMagnitude] {
            Harness.expect(!Formatters.wholeNumber(value).isEmpty, "finite large whole values render")
            Harness.expect(!Formatters.cost(value).isEmpty, "finite large costs render")
        }
        for value in [Double.infinity, -.infinity, .nan, -1] {
            Harness.expectEqual(Formatters.wholeNumber(value), "Unavailable", "invalid whole values are unavailable")
            Harness.expectEqual(Formatters.cost(value), "Unavailable", "invalid costs are unavailable")
            Harness.expectEqual(Formatters.tokens(value), "Unavailable", "invalid token values are unavailable")
        }
    }
}
