import CQuotaBarRust
import Foundation

/// Folds priced recorded usage into the numbers the popover shows.
enum CostAggregator {
    static func snapshot(
        tab: UsageTab,
        reader: RecordedUsageReader,
        rateCard: RateCard,
        windowDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CostSnapshot {
        let calendar = DayKey.gregorianCalendar(in: calendar.timeZone)
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now) ?? now
        let todayKey = DayKey.today(calendar: calendar, now: now)
        let rows = try PricedUsage.price(
            try reader.dailyUsage(tab: tab, fromDay: DayKey.make(from: start, calendar: calendar), rateCard: rateCard)
                .filter { $0.day <= todayKey },
            on: rateCard
        )

        return try Self.aggregate(groupedRows: Dictionary(grouping: rows, by: \.day),
                                  tab: tab, todayKey: todayKey, now: now)
    }

    /// Keep Swift's actual day traversal order: model costs accumulate across days in this order.
    /// The numeric kernel receives compact IDs; strings and public presentation models stay here.
    static func aggregate(groupedRows: [String: [PricedUsage]], tab: UsageTab,
                          todayKey: String, now: Date) throws -> CostSnapshot {
        var dayNames: [String] = []
        var keys: [ModelUsageKey] = []
        var modelIDs: [String: UInt64] = [:]
        var modelNames: [String] = []
        var pricedModelNames: [String?] = []
        var input: [QBAggregateRow] = []
        input.reserveCapacity(groupedRows.values.reduce(0) { $0 + $1.count })
        for (day, dayRows) in groupedRows {
            let dayID = UInt64(dayNames.count)
            dayNames.append(day)
            // Equal Swift strings can have different UTF-8 spellings. Each day's dictionary
            // keeps that day's first key, independently of equivalent keys on other days.
            var keyIDs: [ModelUsageKey: UInt64] = [:]
            for row in dayRows {
                let key = ModelUsageKey(source: row.source, model: row.model, isFast: row.key.isFast,
                                        upstreamProvider: row.key.upstreamProvider)
                let keyID: UInt64
                if let value = keyIDs[key] { keyID = value }
                else { keyID = UInt64(keys.count); keys.append(key); keyIDs[key] = keyID }
                let modelID: UInt64
                if let value = modelIDs[row.model] { modelID = value }
                else {
                    modelID = UInt64(modelNames.count)
                    modelNames.append(row.model)
                    pricedModelNames.append(nil)
                    modelIDs[row.model] = modelID
                }
                // The original cost dictionary starts at the first priced occurrence, which
                // can spell an equivalent model name differently from the token dictionary.
                if row.cost != nil, pricedModelNames[Int(modelID)] == nil {
                    pricedModelNames[Int(modelID)] = row.model
                }
                input.append(QBAggregateRow(day: dayID, key: keyID, model: modelID,
                    tokens: QBAggregateTokens(input: Int64(row.tokens.input), output: Int64(row.tokens.output),
                        cache_write: Int64(row.tokens.cacheWrite), cache_write_1h: Int64(row.tokens.cacheWrite1h),
                        cache_read: Int64(row.tokens.cacheRead)), cost: row.cost ?? 0,
                    unpriced: Int64(row.unpricedTokens), priced: row.cost == nil ? 0 : 1,
                    fallback: row.usesLoggedCostFallback ? 1 : 0))
            }
        }
        var groups = [QBAggregateGroup](repeating: QBAggregateGroup(), count: input.count)
        var dayValues = [QBAggregateDay](repeating: QBAggregateDay(), count: dayNames.count)
        var modelValues = [QBAggregateModel](repeating: QBAggregateModel(), count: modelNames.count)
        var groupCount: UInt64 = 0
        let status = input.withUnsafeBufferPointer { input in
            groups.withUnsafeMutableBufferPointer { groups in
                dayValues.withUnsafeMutableBufferPointer { days in
                    modelValues.withUnsafeMutableBufferPointer { models in
                        qb_aggregate_usage(input.baseAddress, UInt64(input.count), UInt64(days.count), UInt64(models.count),
                                           groups.baseAddress, &groupCount, days.baseAddress, models.baseAddress)
                    }
                }
            }
        }
        try Self.checkAggregationStatus(status)
        var byDay = [[ModelUsageKey: ModelDayUsage]](repeating: [:], count: dayNames.count)
        for group in groups.prefix(Int(groupCount)) {
            byDay[Int(group.day)][keys[Int(group.key)]] = ModelDayUsage(
                tokens: TokenTotals(input: Int(group.tokens.input), output: Int(group.tokens.output),
                    cacheWrite: Int(group.tokens.cache_write), cacheWrite1h: Int(group.tokens.cache_write_1h),
                    cacheRead: Int(group.tokens.cache_read)),
                costUSD: group.priced == 0 ? nil : group.cost, usesLoggedCostFallback: group.fallback != 0)
        }
        var days = dayNames.indices.map { index in
            CostDay(dayKey: dayNames[index], byModel: byDay[index],
                costUSD: dayValues[index].priced == 0 ? nil : dayValues[index].cost,
                unpricedTokens: Int(dayValues[index].unpriced))
        }
        var modelCost: [String: Double] = [:]
        var modelTokens: [String: Int] = [:]
        for index in modelNames.indices {
            if modelValues[index].priced != 0, let name = pricedModelNames[index] {
                modelCost[name] = modelValues[index].cost
            }
            modelTokens[modelNames[index]] = Int(modelValues[index].tokens)
        }
        let hasUnpriced = dayValues.contains { $0.unpriced > 0 }

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
            tab: tab,
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

    private static func checkAggregationStatus(_ status: Int32) throws {
        let message: String
        switch status {
        case 0: return
        case 1: message = "token counts are negative or exceed the integer range"
        case 2: message = "token aggregation exceeds the integer range"
        case 3: message = "total tokens exceed the integer range"
        case 4: message = "window token total exceeds the integer range"
        case 5: message = "aggregate cost is not finite and nonnegative"
        default: message = "Rust usage aggregation failed"
        }
        throw RecordedUsageReaderError.invalidData(message)
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
