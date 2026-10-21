// The price book with the third-party rates beside it. Every rate the app bills, shows, or scans
// against is looked up here, so which source prices a model, how Fast is priced, and when a
// request is in the long-context tier are each decided in one place.

import Foundation

public struct RateCard: Sendable {
    /// Where a model's rates come from.
    public enum Source: Sendable, Equatable {
        /// The bundled price book, kept by hand for Claude and OpenAI models.
        case priceBook
        /// The local cache of models.dev rates, for every other model.
        case modelsDev
    }

    public let book: PriceBook
    public let thirdParty: ThirdPartyRates

    public init(book: PriceBook = .bundled, thirdParty: ThirdPartyRates = .empty) {
        self.book = book
        self.thirdParty = thirdParty
    }

    /// The shipped book with the third-party rates cached on this machine, unless that setting
    /// is off.
    public static func onDisk(book: PriceBook = .bundled, modelsDev: ModelsDevPricing = .live) -> RateCard {
        RateCard(book: book, thirdParty: modelsDev.rates())
    }

    /// The id a model is priced and grouped under: `openai/gpt-5.1-2026-01-01` -> `gpt-5.1`,
    /// `anthropic.claude-opus-5-v1:0` -> `claude-opus-5`, `openrouter/z-ai/glm-5` -> `glm-5`, and
    /// an alias the book lists -> the model it stands for.
    ///
    /// This is the only place a name becomes a model ID. It accepts a raw log name, the cleaned-up
    /// name Recorded usage keeps, or an ID, which resolves to itself. Resolving at read time means
    /// an alias a later book adds prices usage recorded before it, and usage recorded under an
    /// older spelling lands on the same model as today's.
    public func modelID(for name: String, provider: Provider) -> String {
        self.book.canonicalID(for: ModelNames.stripped(name, provider: provider), provider: provider)
    }

    /// Whether a name stands for a model at all. Tokens whose model the log did not name are
    /// recorded under a sentinel that is never priced or listed.
    public static func isKnown(_ name: String) -> Bool {
        !name.isEmpty && name != CostPricing.unknownModel
    }

    /// Usage totals regrouped under the model ID each name resolves to on this card, most-used
    /// first, without the unknown-model sentinel. An alias, its dated or vendor-prefixed
    /// spellings, and the ID itself are one model, so their totals add up.
    public func modelUsage(_ usage: [ModelUsageTotal], provider: Provider) -> [ModelUsageTotal] {
        let tokens = Dictionary(
            usage.lazy.map { (self.modelID(for: $0.model, provider: provider), $0.tokens) }
                .filter { Self.isKnown($0.0) },
            uniquingKeysWith: +
        )
        return tokens.map { ModelUsageTotal(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model }
    }

    /// Which source prices a model, or nil when neither does. A model the book lists is the
    /// book's on every day, even one it leaves unpriced. Every lookup below takes any spelling
    /// `modelID(for:provider:)` accepts.
    public func source(for model: String, provider: Provider) -> Source? {
        let id = self.modelID(for: model, provider: provider)
        guard Self.isKnown(id) else { return nil }
        if self.book.model(id, provider: provider) != nil { return .priceBook }
        return self.thirdParty.prices(id) ? .modelsDev : nil
    }

    /// Rates in force for a model on `day` (`yyyy-MM-dd`), or nil when nothing prices it.
    public func rates(for model: String, provider: Provider, day: String, fast: Bool = false) -> ModelPricing? {
        let id = self.modelID(for: model, provider: provider)
        switch self.source(for: id, provider: provider) {
        case .priceBook:
            return self.book.rates(for: id, provider: provider, day: day, fast: fast)
        case .modelsDev:
            // models.dev publishes no Fast tier, so Fast usage of a third-party model stays unpriced.
            return fast ? nil : self.thirdParty.rates(for: id, day: day)
        case nil:
            return nil
        }
    }

    /// Whether one request's input and cache tokens cross the model's long-context threshold.
    /// Scanners settle this per request, since rows are aggregated per day afterwards.
    ///
    /// models.dev only ever describes a tier above 200K tokens, so a third-party request is
    /// classified against that threshold whether or not its rates have been downloaded yet, or
    /// models.dev pricing is on. A model without long-context rates bills the tier at its base rates.
    public func isLongContext(
        _ request: TokenTotals,
        model: String,
        provider: Provider,
        day: String,
        fast: Bool = false
    ) -> Bool {
        let id = self.modelID(for: model, provider: provider)
        let threshold: Int?
        if Self.isKnown(id), self.book.model(id, provider: provider) == nil, ThirdPartyRates.isThirdParty(id) {
            threshold = fast ? nil : ModelsDevCatalog.longContextThreshold
        } else {
            threshold = self.rates(for: id, provider: provider, day: day, fast: fast)?.thresholdTokens
        }
        guard let threshold else { return false }
        return request.input + request.cacheRead + request.cacheWrite > threshold
    }

    /// Cost in USD, or nil for unpriced usage: tokens whose model has no rate on their day.
    public func cost(
        of totals: TokenTotals,
        model: String,
        provider: Provider,
        day: String,
        fast: Bool = false,
        longContext: Bool
    ) -> Double? {
        self.rates(for: model, provider: provider, day: day, fast: fast)?.cost(for: totals, longContext: longContext)
    }

    /// The models the pricing settings list for a provider before any appear in local logs, in
    /// the order the book gives them.
    public func settingsModels(for provider: Provider) -> [String] {
        self.book.models(for: provider).filter(\.showInSettings).map(\.id)
    }
}
