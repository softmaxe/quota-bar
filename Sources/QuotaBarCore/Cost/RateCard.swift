// The price book with the user's overrides laid over it. Every rate the app bills, shows, or
// scans against is looked up here, so what an override replaces, how Fast is priced, and when a
// request is in the long-context tier are each decided in one place.

import Foundation

public struct RateCard: Sendable {
    public let book: PriceBook
    /// Keyed by model id. Each one replaces the book's Standard rates for that model on every day.
    public let overrides: [String: ModelPricing]

    public init(book: PriceBook = .bundled, overrides: [String: ModelPricing] = [:]) {
        self.book = book
        self.overrides = overrides
    }

    /// The shipped book with the overrides saved on this machine.
    public static func onDisk(book: PriceBook = .bundled, file: OverrideFile = OverrideFile()) -> RateCard {
        RateCard(book: book, overrides: file.load())
    }

    /// The same book with no overrides: what a model falls back to when its override is removed.
    public var withoutOverrides: RateCard {
        RateCard(book: self.book)
    }

    /// The id a model is stored and priced under: `openai/gpt-5.1-2026-01-01` -> `gpt-5.1`,
    /// `anthropic.claude-opus-5-v1:0` -> `claude-opus-5`, and an alias the book lists -> the model
    /// it stands for.
    public func modelID(for name: String, provider: Provider) -> String {
        self.book.canonicalID(for: ModelNames.stripped(name, provider: provider), provider: provider)
    }

    /// Rates in force for a model on `day` (`yyyy-MM-dd`), or nil when nothing prices it. `model`
    /// is a model id as `modelID(for:provider:)` gives it, which is how usage is stored; it is
    /// looked up as is, so recorded usage is priced under the name it was recorded with.
    public func rates(for model: String, provider: Provider, day: String, fast: Bool = false) -> ModelPricing? {
        guard model != CostPricing.unknownModel, !model.isEmpty else { return nil }
        // Fast is a multiple of the book's Standard rates; an override states Standard rates only,
        // so it cannot say what Fast costs, and an unknown Fast model stays unpriced.
        if provider == .codex, fast {
            return self.book.rates(for: model, provider: provider, day: day, fast: true)
        }
        return self.overrides[model] ?? self.book.rates(for: model, provider: provider, day: day)
    }

    /// Whether one request's input and cache tokens cross the model's long-context threshold.
    /// Scanners settle this per request, since rows are aggregated per day afterwards.
    public func isLongContext(
        _ request: TokenTotals,
        model: String,
        provider: Provider,
        day: String,
        fast: Bool = false
    ) -> Bool {
        guard let threshold = self.rates(for: model, provider: provider, day: day, fast: fast)?.thresholdTokens
        else { return false }
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
