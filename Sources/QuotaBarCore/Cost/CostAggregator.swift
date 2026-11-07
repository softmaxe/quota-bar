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
        let todayKey = DayKey.today(calendar: calendar, now: now)
        let rows = try PricedUsage.price(
            try reader.dailyUsage(provider: provider, fromDay: DayKey.make(from: start, calendar: calendar))
                .filter { $0.day <= todayKey },
            on: rateCard
        )

        var days: [CostDay] = []
        // Cost and token totals per model across the whole window, for picking the top model.
        var modelCost: [String: Double] = [:]
        var modelTokens: [String: Int] = [:]
        var hasUnpriced = false

        for (dayKey, dayRows) in Dictionary(grouping: rows, by: \.day) {
            var dayTokens: [ModelUsageKey: TokenTotals] = [:]
            var checkedDayTokens = TokenTotals()
            // Per-source/model cost stays nil until something prices it, so an unpriced row reads
            // as "no price" in the breakdown rather than as zero dollars.
            var dayCostByModel: [ModelUsageKey: Double] = [:]
            var dayCost = 0.0
            var dayPriced = false
            var dayUnpricedTokens = 0

            for row in dayRows {
                let usageKey = ModelUsageKey(source: row.source, model: row.model, isFast: row.key.isFast)
                dayTokens[usageKey] = try dayTokens[usageKey, default: TokenTotals()].adding(row.tokens)
                checkedDayTokens = try checkedDayTokens.adding(row.tokens)
                modelTokens[row.model] = try self.add(modelTokens[row.model, default: 0], row.tokens.total)
                if let cost = row.cost {
                    dayCost = try self.add(dayCost, cost)
                    dayPriced = true
                    dayCostByModel[usageKey] = try self.add(dayCostByModel[usageKey, default: 0], cost)
                    modelCost[row.model] = try self.add(modelCost[row.model, default: 0], cost)
                } else if row.unpricedTokens > 0 {
                    hasUnpriced = true
                    dayUnpricedTokens = try self.add(dayUnpricedTokens, row.unpricedTokens)
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

        var todayCostUSD = 0.0
        var windowCostUSD = 0.0
        var latestTokens = 0
        var windowTokens = 0
        for day in days {
            if day.dayKey == todayKey { todayCostUSD = day.costUSD ?? 0 }
            windowCostUSD = try self.add(windowCostUSD, day.costUSD ?? 0)
            latestTokens = day.tokens.total
            windowTokens = try self.add(windowTokens, latestTokens)
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

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else {
            throw RecordedUsageReaderError.invalidData("window token total exceeds the integer range")
        }
        return result.partialValue
    }

    private static func add(_ lhs: Double, _ rhs: Double) throws -> Double {
        let result = lhs + rhs
        guard lhs >= 0, rhs >= 0, result.isFinite else {
            throw RecordedUsageReaderError.invalidData("aggregate cost is not finite and nonnegative")
        }
        return result
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
