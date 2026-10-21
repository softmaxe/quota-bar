import Foundation

/// Folds priced recorded usage into the numbers the popover shows.
enum CostAggregator {
    static func snapshot(
        provider: Provider,
        reader: RecordedUsageReader,
        rateCard: RateCard,
        windowDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CostSnapshot {
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now) ?? now
        let rows = PricedUsage.price(
            try reader.dailyUsage(provider: provider, fromDay: DayKey.make(from: start, calendar: calendar)),
            on: rateCard
        )

        var days: [CostDay] = []
        // Cost and token totals per model across the whole window, for picking the top model.
        var modelCost: [String: Double] = [:]
        var modelTokens: [String: Int] = [:]
        var hasUnpriced = false

        for (dayKey, dayRows) in Dictionary(grouping: rows, by: \.day) {
            var dayTokens: [ModelUsageKey: TokenTotals] = [:]
            // Per-source/model cost stays nil until something prices it, so an unpriced row reads
            // as "no price" in the breakdown rather than as zero dollars.
            var dayCostByModel: [ModelUsageKey: Double] = [:]
            var dayCost = 0.0
            var dayPriced = false
            var dayUnpricedTokens = 0

            for row in dayRows {
                let usageKey = ModelUsageKey(source: row.source, model: row.model, isFast: row.key.isFast)
                dayTokens[usageKey, default: TokenTotals()] += row.tokens
                modelTokens[row.model, default: 0] += row.tokens.total
                if let cost = row.cost {
                    dayCost += cost
                    dayPriced = true
                    dayCostByModel[usageKey, default: 0] += cost
                    modelCost[row.model, default: 0] += cost
                } else if row.unpricedTokens > 0 {
                    hasUnpriced = true
                    dayUnpricedTokens += row.unpricedTokens
                }
            }

            let byModel = Dictionary(uniqueKeysWithValues: dayTokens.lazy.map { key, tokens in
                (key, ModelDayUsage(tokens: tokens, costUSD: dayCostByModel[key]))
            })

            days.append(CostDay(
                dayKey: dayKey,
                byModel: byModel,
                costUSD: dayPriced ? dayCost : nil,
                unpricedTokens: dayUnpricedTokens
            ))
        }

        days.sort { $0.dayKey < $1.dayKey }

        let todayKey = DayKey.today(calendar: calendar, now: now)
        var todayCostUSD = 0.0
        var windowCostUSD = 0.0
        var latestTokens = 0
        var windowTokens = 0
        for day in days {
            if day.dayKey == todayKey { todayCostUSD = day.costUSD ?? 0 }
            windowCostUSD += day.costUSD ?? 0
            latestTokens = day.tokens.total
            windowTokens += latestTokens
        }

        return CostSnapshot(
            provider: provider,
            days: days,
            todayCostUSD: todayCostUSD,
            windowCostUSD: windowCostUSD,
            latestTokens: latestTokens,
            windowTokens: windowTokens,
            topModel: Self.topModel(cost: modelCost, tokens: modelTokens),
            hasUnpricedTokens: hasUnpriced,
            scannedAt: now
        )
    }

    /// Highest accumulated cost wins; models with equal cost fall back to token count.
    static func topModel(cost: [String: Double], tokens: [String: Int]) -> String? {
        let candidates = Set(cost.keys).union(tokens.keys).filter(RateCard.isKnown)
        return candidates.max { lhs, rhs in
            let lhsCost = cost[lhs] ?? 0
            let rhsCost = cost[rhs] ?? 0
            if lhsCost != rhsCost { return lhsCost < rhsCost }
            return (tokens[lhs] ?? 0) < (tokens[rhs] ?? 0)
        }
    }
}
