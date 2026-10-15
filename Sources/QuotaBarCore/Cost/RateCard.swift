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
    /// `anthropic.claude-opus-5-v1:0` -> `claude-opus-5`, and an alias the book lists -> the model
    /// it stands for.
    public func modelID(for name: String, provider: Provider) -> String {
        self.modelID(recordedAs: ModelNames.stripped(name, provider: provider), provider: provider)
    }

    /// The id recorded usage is priced and grouped under. Recorded usage keeps the cleaned-up
    /// name its log reported, so an alias resolves here, against the card usage is read with, and
    /// an alias a later book adds prices usage recorded before it. An id resolves to itself.
    public func modelID(recordedAs name: String, provider: Provider) -> String {
        self.book.canonicalID(for: name, provider: provider)
    }

    /// Usage totals regrouped under the model ID each name resolves to on this card, most-used
    /// first. An alias, its dated or vendor-prefixed spellings, and the ID itself are one model,
    /// so their totals add up.
    public func modelUsage(_ usage: [ModelUsageTotal], provider: Provider) -> [ModelUsageTotal] {
        let tokens = Dictionary(usage.map { (self.modelID(for: $0.model, provider: provider), $0.tokens) }, uniquingKeysWith: +)
        return tokens.map { ModelUsageTotal(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model }
    }

    /// Which source prices a model, or nil when neither does. A model the book lists is the
    /// book's on every day, even one it leaves unpriced.
    public func source(for model: String, provider: Provider) -> Source? {
        guard model != CostPricing.unknownModel, !model.isEmpty else { return nil }
        if self.book.model(model, provider: provider) != nil { return .priceBook }
        return self.thirdParty.prices(model) ? .modelsDev : nil
    }

    /// Rates in force for a model on `day` (`yyyy-MM-dd`), or nil when nothing prices it. `model`
    /// is a model id as `modelID(for:provider:)` gives it and is looked up as is, so a recorded
    /// name must be resolved first.
    public func rates(for model: String, provider: Provider, day: String, fast: Bool = false) -> ModelPricing? {
        switch self.source(for: model, provider: provider) {
        case .priceBook:
            return self.book.rates(for: model, provider: provider, day: day, fast: fast)
        case .modelsDev:
            // models.dev publishes no Fast tier, so Fast usage of a third-party model stays unpriced.
            return fast ? nil : self.thirdParty.rates(for: model, day: day)
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
        let threshold: Int?
        if self.book.model(model, provider: provider) == nil, ThirdPartyRates.isThirdParty(model),
           model != CostPricing.unknownModel, !model.isEmpty {
            threshold = fast ? nil : ModelsDevCatalog.longContextThreshold
        } else {
            threshold = self.rates(for: model, provider: provider, day: day, fast: fast)?.thresholdTokens
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
