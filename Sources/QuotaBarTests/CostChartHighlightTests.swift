@testable import QuotaBarApp
import Foundation
import QuotaBarCore

/// Calendar slots, stale scan coverage, price availability, and date selection.
enum CostChartHighlightTests {
    static func run() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let priced = self.day("2026-09-05", tokens: 200, cost: 10, unpriced: 0)
        let partial = self.day("2026-09-09", tokens: 50, cost: 3, unpriced: 20)
        let unpriced = self.day("2026-09-13", tokens: 70, cost: nil, unpriced: 70)
        let days = CostChartHighlightPolicy.visibleDays(
            from: [priced, partial, unpriced],
            todayDayKey: "2026-09-14",
            maxBars: 10,
            calendar: calendar
        )
        let keys = days.map(\.dayKey)
        let expectedKeys = (5...14).map { String(format: "2026-09-%02d", $0) }
        Harness.expectEqual(keys, expectedKeys, "ten calendar slots expected Sep 5–14, got \(keys)")
        Harness.expect(!(days.count != 10 || days[1].tokens.total != 0 || days[1].costAvailability != .zero), "an empty completed-scan date expected a known zero")
        let staleScan = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let staleKeys = CostChartHighlightPolicy.unobservedDayKeys(
            visibleDays: days,
            recordedDays: [priced, partial],
            scannedAt: staleScan,
            calendar: calendar
        )
        Harness.expect(!(staleKeys != Set(["2026-09-11", "2026-09-12", "2026-09-13", "2026-09-14"])
            || staleKeys.contains("2026-09-06")
            || staleKeys.contains(partial.dayKey)), "a stale scan expected future missing dates unknown and scanned history intact")
        let recordedAfterScan = CostChartHighlightPolicy.unobservedDayKeys(
            visibleDays: days,
            recordedDays: [priced, partial, unpriced],
            scannedAt: staleScan,
            calendar: calendar
        )
        Harness.expect(!(recordedAfterScan.contains(unpriced.dayKey) || !recordedAfterScan.contains("2026-09-14")), "recorded usage expected precedence over a stale scan timestamp")
        let completedScan = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let completedKeys = CostChartHighlightPolicy.unobservedDayKeys(
            visibleDays: days,
            recordedDays: [priced, partial, unpriced],
            scannedAt: completedScan,
            calendar: calendar
        )
        Harness.expect(!(!completedKeys.isEmpty || days.last?.costAvailability != .zero), "a completed same-day scan expected a known zero for missing today")
        let crossingMonth = CostChartHighlightPolicy.visibleDays(
            from: [],
            todayDayKey: "2026-10-03",
            maxBars: 10,
            calendar: calendar
        ).map(\.dayKey)
        Harness.expect(!(crossingMonth.first != "2026-09-24" || crossingMonth.last != "2026-10-03"), "calendar slots expected to cross the month boundary")
        Harness.expect(!(CostChartHighlightPolicy.visibleDays(
            from: [], todayDayKey: "invalid", maxBars: 10, calendar: calendar
        ).count != 0), "an invalid date key expected no invented slots")

        Harness.expect(!(priced.costAvailability.state != .priced
            || priced.costAvailability.knownUSD != 10
            || partial.costAvailability.state != .partial
            || partial.costAvailability.knownUSD != 3
            || partial.costAvailability.unpricedTokens != 20
            || unpriced.costAvailability.state != .unpriced
            || unpriced.costAvailability.knownUSD != nil), "pricing availability expected priced, partial, and unpriced states")
        let snapshot = CostSnapshot(
            provider: .codex,
            days: [priced, partial, unpriced],
            todayCostUSD: 0,
            windowCostUSD: 13,
            latestTokens: 70,
            windowTokens: 320,
            topModel: nil,
            hasUnpricedTokens: true,
            scannedAt: completedScan
        )
        Harness.expect(!(snapshot.windowCostAvailability.state != .partial
            || snapshot.windowCostAvailability.knownUSD != 13
            || snapshot.windowCostAvailability.unpricedTokens != 90
            || snapshot.costAvailability(forDayKey: "2026-09-14") != .zero), "window availability expected the known subtotal and unpriced count")
        let allUnpriced = CostAvailability(knownUSD: 0, totalTokens: 40, unpricedTokens: 40)
        Harness.expect(!(allUnpriced.state != .unpriced || allUnpriced.knownUSD != nil), "fully unpriced usage expected no false $0.00 amount")

        Harness.expect(!(CostChartHighlightPolicy.value(for: priced, mode: .tokens) != 200
            || CostChartHighlightPolicy.value(for: priced, mode: .cost) != 10
            || CostChartHighlightPolicy.maxValue(for: days, mode: .cost) != 10), "chart values expected to follow the selected unit")
        let available = Set(keys)
        let selected = CostChartHighlightPolicy.selectedDayKey(
            pinnedDayKey: "2026-09-09",
            hoveredDayKey: "2026-09-13",
            detailDayKey: "2026-09-14",
            availableDayKeys: available,
            defaultDayKey: "2026-09-14"
        )
        let refreshed = CostChartHighlightPolicy.selectedDayKey(
            pinnedDayKey: "missing",
            hoveredDayKey: nil,
            detailDayKey: nil,
            availableDayKeys: available,
            defaultDayKey: "2026-09-14"
        )
        Harness.expect(!(selected != "2026-09-09" || refreshed != "2026-09-14"), "pinning expected precedence and stale-date fallback")
        Harness.expect(!(CostChartHighlightPolicy.nextDayKey(
            from: "2026-09-09", direction: -1, days: days
        ) != "2026-09-08"
            || CostChartHighlightPolicy.nextDayKey(
                from: "2026-09-09", direction: 1, days: days
            ) != "2026-09-10"
            || CostChartHighlightPolicy.nextDayKey(
                from: "2026-09-05", direction: -1, days: days
            ) != "2026-09-05"), "arrow navigation expected adjacent dates and bounded ends")
        Harness.expect(!(CostChartHighlightPolicy.opacity(
            dayKey: "2026-09-09", selectedDayKey: selected
        ) != 1 || CostChartHighlightPolicy.opacity(
            dayKey: "2026-09-08", selectedDayKey: selected
        ) != CostChartHighlightPolicy.restingOpacity), "selected-day marker tone expected one active column")
    }

    private static func day(
        _ key: String,
        tokens: Int,
        cost: Double?,
        unpriced: Int
    ) -> CostDay {
        let usageKey = ModelUsageKey(source: .codex, model: "fixture")
        return CostDay(
            dayKey: key,
            byModel: [
                usageKey: ModelDayUsage(tokens: TokenTotals(input: tokens), costUSD: cost),
            ],
            costUSD: cost,
            unpricedTokens: unpriced
        )
    }
}
