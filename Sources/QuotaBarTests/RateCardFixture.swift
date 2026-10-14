import Foundation
import QuotaBarCore

extension RateCard {
    /// A rate card whose book lists exactly these models, each with one period of the given
    /// Standard rates and no Fast tier, beside the given third-party rates.
    static func fixture(
        codex: [String: ModelPricing] = [:],
        claude: [String: ModelPricing] = [:],
        thirdParty: [String: ModelPricing] = [:]
    ) -> RateCard {
        var providers: [String] = []
        for (provider, models) in [("codex", codex), ("claude", claude)] where !models.isEmpty {
            let entries = models.keys.sorted().map { id in
                #"{ "id": "\#(id)", "periods": [ { "rates": \#(Self.json(models[id]!)) } ] }"#
            }
            providers.append(#""\#(provider)": { "source": "https://example.com", "checkedAt": "2026-09-01", "models": [\#(entries.joined(separator: ", "))] }"#)
        }
        let book: PriceBook
        do {
            book = try PriceBook(data: Data(#"{ "schemaVersion": 1, "providers": { \#(providers.joined(separator: ", ")) } }"#.utf8))
        } catch {
            Harness.expect(false, "fixture rate card book threw: \(error)")
            book = .bundled
        }
        return RateCard(book: book, thirdParty: ThirdPartyRates(current: thirdParty))
    }

    private static func json(_ rates: ModelPricing) -> String {
        var fields = [("input", rates.input), ("output", rates.output)]
        fields += ModelPricing.optionalRates.compactMap { rate in rates[keyPath: rate.value].map { (rate.json, $0) } }
        if let threshold = rates.thresholdTokens { fields.append(("thresholdTokens", Double(threshold))) }
        return "{ " + fields.map { #""\#($0.0)": \#($0.1)"# }.joined(separator: ", ") + " }"
    }
}
