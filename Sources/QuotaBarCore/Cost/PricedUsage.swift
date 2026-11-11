import Foundation

/// Recorded usage priced on one rate card: rows grouped under the model ID each recorded name
/// resolves to, each with its cost at that model's rates for its day, or none for Unpriced usage.
/// The menu and the usage report both fold over these rows, so they agree on every day.
package struct PricedUsage: Equatable {
    package struct Key: Hashable {
        package let day: String
        package let source: CostUsageSource
        /// The model ID the rate card resolves the recorded name to.
        package let model: String
        package let longContext: Bool
        package let isFast: Bool
        package let upstreamProvider: String?
        package let pricingProvider: Provider
    }

    package let key: Key
    package let tokens: TokenTotals
    /// USD at the rates in force on the row's day. nil when nothing prices the model that day,
    /// and for a row without tokens, which costs nothing either way.
    package let cost: Double?
    /// Tokens that count toward totals but not toward cost.
    package let unpricedTokens: Int
    package let usesLoggedCostFallback: Bool

    package var day: String { self.key.day }
    package var source: CostUsageSource { self.key.source }
    package var model: String { self.key.model }

    /// Rows read from the recorded usage, regrouped and priced. Spellings that resolve to one
    /// model on this card coalesce while preserving partially priced fallback usage.
    /// Order follows day, source, model, and upstream provider.
    package static func price(_ rows: [RecordedUsageReader.DayUsage], on rateCard: RateCard) throws -> [PricedUsage] {
        var grouped: [Key: PricedUsage] = [:]
        for row in rows {
            let provider = row.tier.source.pricingProvider(model: row.tier.model, upstreamProvider: row.tier.upstreamProvider)
            let key = Key(
                day: row.day,
                source: row.tier.source,
                model: rateCard.modelID(for: row.tier.model, provider: provider),
                longContext: row.tier.longContext,
                isFast: row.tier.isFast,
                upstreamProvider: row.tier.upstreamProvider,
                pricingProvider: provider
            )
            let hasRate = rateCard.rates(for: key.model, provider: provider, day: key.day, fast: key.isFast) != nil
            let fallback = row.tokens.total > 0 && !hasRate && key.source == .piAgent
                && (row.loggedCostUSD.map { $0.isFinite && $0 > 0 } ?? false)
            let cost = hasRate && row.tokens.total > 0
                ? rateCard.cost(of: row.tokens, model: key.model, provider: provider, day: key.day,
                                fast: key.isFast, longContext: key.longContext)
                : (fallback ? row.loggedCostUSD : nil)
            let unpriced = cost == nil ? row.tokens.total : (fallback ? row.tokens.total - row.loggedCostTokens : 0)
            let previous = grouped[key]
            let combinedCost: Double? = cost == nil && previous?.cost == nil ? nil : (cost ?? 0) + (previous?.cost ?? 0)
            guard combinedCost?.isFinite ?? true else {
                throw RecordedUsageReaderError.invalidData("cost aggregation exceeds the numeric range")
            }
            grouped[key] = PricedUsage(key: key,
                tokens: try (previous?.tokens ?? TokenTotals()).adding(row.tokens), cost: combinedCost,
                unpricedTokens: try TokenTotals(input: previous?.unpricedTokens ?? 0).adding(TokenTotals(input: unpriced)).input,
                usesLoggedCostFallback: fallback || (previous?.usesLoggedCostFallback ?? false))
        }
        return grouped.values.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.source != rhs.source { return lhs.source.displayOrder < rhs.source.displayOrder }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            if lhs.key.upstreamProvider != rhs.key.upstreamProvider { return (lhs.key.upstreamProvider ?? "") < (rhs.key.upstreamProvider ?? "") }
            if lhs.key.longContext != rhs.key.longContext { return !lhs.key.longContext }
            return !lhs.key.isFast && rhs.key.isFast
        }
    }
}
