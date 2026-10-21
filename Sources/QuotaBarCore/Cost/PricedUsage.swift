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
    }

    package let key: Key
    package let tokens: TokenTotals
    /// USD at the rates in force on the row's day. nil when nothing prices the model that day,
    /// and for a row without tokens, which costs nothing either way.
    package let cost: Double?

    package var day: String { self.key.day }
    package var source: CostUsageSource { self.key.source }
    package var model: String { self.key.model }

    /// Tokens that count toward totals but not toward cost.
    package var unpricedTokens: Int { self.cost == nil ? self.tokens.total : 0 }

    /// Rows read from the recorded usage, regrouped and priced. Spellings that resolve to one
    /// model on this card add up before they are priced. Order follows day, then source, then
    /// model.
    package static func price(_ rows: [RecordedUsageReader.DayUsage], on rateCard: RateCard) -> [PricedUsage] {
        var grouped: [Key: TokenTotals] = [:]
        for row in rows {
            let key = Key(
                day: row.day,
                source: row.tier.source,
                model: rateCard.modelID(for: row.tier.model, provider: row.tier.source.provider),
                longContext: row.tier.longContext,
                isFast: row.tier.isFast
            )
            grouped[key, default: TokenTotals()] += row.tokens
        }
        return grouped.map { key, tokens in
            let cost = tokens.total > 0
                ? rateCard.cost(
                    of: tokens,
                    model: key.model,
                    provider: key.source.provider,
                    day: key.day,
                    fast: key.isFast,
                    longContext: key.longContext
                )
                : nil
            return PricedUsage(key: key, tokens: tokens, cost: cost)
        }.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.source != rhs.source { return lhs.source.displayOrder < rhs.source.displayOrder }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            if lhs.key.longContext != rhs.key.longContext { return !lhs.key.longContext }
            return !lhs.key.isFast && rhs.key.isFast
        }
    }
}
