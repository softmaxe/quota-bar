// Reads `models.dev/api.json` into one set of rates per third-party model. The catalog lists the
// same model under every provider that serves it, at prices that differ by reseller, so this
// settles on one: the model maker's own listing when there is one, otherwise the middle price.

import Foundation

public enum ModelsDevCatalog {
    public static let url = URL(string: "https://models.dev/api.json")!
    /// The one long-context tier models.dev describes: `context_over_200k`.
    public static let longContextThreshold = 200_000

    public enum Error: Swift.Error, LocalizedError {
        case notACatalog
        case empty
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .notACatalog: "models.dev did not return a provider catalog"
            case .empty: "models.dev listed no priced models"
            case let .http(status): "models.dev answered HTTP \(status)"
            }
        }
    }

    public static func download(session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: Self.url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw Error.http(status)
        }
        return data
    }

    /// The models whose makers are behind the price book. Their listings are skipped whatever
    /// they are named.
    private static let bookMakers: Set<String> = ["openai", "anthropic"]

    private struct Listing {
        let provider: String
        let maker: String?
        let rates: ModelPricing
    }

    /// A model as the catalog settles it: one set of rates, and who makes it when a listing says.
    package struct Model: Sendable, Equatable {
        package let rates: ModelPricing
        /// The vendor part of `canonical_model_id`, such as `deepseek`.
        package let maker: String?
    }

    /// One set of rates per model, keyed as `ThirdPartyRates.key(for:)` spells it.
    package static func rates(from data: Data) throws -> [String: ModelPricing] {
        try Self.models(from: data).mapValues(\.rates)
    }

    /// Every model the catalog prices, keyed as `ThirdPartyRates.key(for:)` spells it. A model
    /// every listing gives away free is left out, so its usage stays unpriced rather than costing
    /// nothing.
    package static func models(from data: Data) throws -> [String: Model] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.notACatalog
        }
        var listings: [String: [Listing]] = [:]
        for (providerID, value) in root {
            guard let provider = value as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            let providerID = providerID.lowercased()
            for (modelID, raw) in models {
                guard let model = raw as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let rates = Self.pricing(cost) else { continue }
                let canonical = (model["canonical_model_id"] as? String)?.lowercased()
                let maker = canonical.flatMap { $0.contains("/") ? String($0.prefix { $0 != "/" }) : nil }
                let listing = Listing(provider: providerID, maker: maker, rates: rates)
                let name = ThirdPartyRates.key(for: modelID)
                listings[name, default: []].append(listing)
                // A maker may list a model under a short name of its own, such as DeepSeek's
                // `deepseek-flash` for `deepseek-v4.1-flash`. File that listing under the
                // canonical name too, so the maker's price is found under either.
                if let canonical, providerID == maker {
                    let canonicalName = ThirdPartyRates.key(for: canonical)
                    if canonicalName != name { listings[canonicalName, default: []].append(listing) }
                }
            }
        }
        if listings.isEmpty { throw Error.notACatalog }

        var result: [String: Model] = [:]
        for (name, candidates) in listings where ThirdPartyRates.isThirdParty(name) {
            let maker = Self.mostCommon(candidates.compactMap(\.maker))
            if let maker, Self.bookMakers.contains(maker) { continue }
            let paid = candidates.filter { $0.rates.input > 0 || $0.rates.output > 0 }
            let own = paid.filter { $0.provider == maker }
            if let chosen = Self.middle(own.isEmpty ? paid : own) {
                result[name] = Model(rates: chosen.rates, maker: maker)
            }
        }
        return result
    }

    /// A listing's cost object, in USD per million tokens like the price book. Rates above
    /// 200K tokens become the long-context tier; models.dev's other context tiers are not read.
    private static func pricing(_ cost: [String: Any]) -> ModelPricing? {
        guard let input = Self.number(cost["input"]), let output = Self.number(cost["output"]) else { return nil }
        var rates = ["input": input, "output": output]
        rates["cacheRead"] = Self.number(cost["cache_read"])
        rates["cacheWrite"] = Self.number(cost["cache_write"])
        if let above = cost["context_over_200k"] as? [String: Any],
           let inputAbove = Self.number(above["input"]), let outputAbove = Self.number(above["output"]) {
            rates["thresholdTokens"] = Double(Self.longContextThreshold)
            rates["inputAbove"] = inputAbove
            rates["outputAbove"] = outputAbove
            rates["cacheReadAbove"] = Self.number(above["cache_read"])
            rates["cacheWriteAbove"] = Self.number(above["cache_write"])
        }
        return try? ModelPricing(rates: rates)
    }

    /// The listing priced in the middle, so one reseller's discount or markup does not set the
    /// estimate. Ties go to the lower price and then the provider's name, so a fetch of the same
    /// catalog always picks the same listing.
    private static func middle(_ listings: [Listing]) -> Listing? {
        guard !listings.isEmpty else { return nil }
        let sorted = listings.sorted {
            if $0.rates.input != $1.rates.input { return $0.rates.input < $1.rates.input }
            if $0.rates.output != $1.rates.output { return $0.rates.output < $1.rates.output }
            return $0.provider < $1.provider
        }
        return sorted[(sorted.count - 1) / 2]
    }

    private static func mostCommon(_ names: [String]) -> String? {
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// JSON numbers only; booleans also bridge to NSNumber and are rejected.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
