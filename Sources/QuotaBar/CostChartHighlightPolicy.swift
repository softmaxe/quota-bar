import Foundation
import QuotaBarCore

enum CostChartHighlightPolicy {
    static let restingOpacity = 0.55

    static func value(for day: CostDay, mode: CostChartLabelMode) -> Double {
        switch mode {
        case .tokens: Double(day.tokens.total)
        case .cost: day.costAvailability.knownUSD ?? 0
        }
    }

    static func maxValue(for days: [CostDay], mode: CostChartLabelMode) -> Double {
        days.map { self.value(for: $0, mode: mode) }.max() ?? 0
    }

    /// Each slot is one local calendar day. Callers distinguish scan coverage from absence.
    static func visibleDays(
        from days: [CostDay],
        todayDayKey: String,
        maxBars: Int,
        calendar: Calendar = .current
    ) -> [CostDay] {
        guard maxBars > 0,
              let today = self.date(from: todayDayKey, calendar: calendar) else { return [] }
        let byKey = Dictionary(days.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, newer in newer })
        return (0..<maxBars).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - maxBars + 1, to: today) else {
                return nil
            }
            let key = DayKey.make(from: date, calendar: calendar)
            return byKey[key] ?? CostDay(
                dayKey: key,
                byModel: [:],
                costUSD: 0,
                unpricedTokens: 0
            )
        }
    }

    /// Missing dates after the last completed scan are unknown, even when a stale snapshot is
    /// displayed while a later scan is pending or failed. Recorded data always takes precedence.
    static func unobservedDayKeys(
        visibleDays: [CostDay],
        recordedDays: [CostDay],
        scannedAt: Date,
        calendar: Calendar = .current
    ) -> Set<String> {
        let scannedThroughKey = DayKey.make(from: scannedAt, calendar: calendar)
        let recordedKeys = Set(recordedDays.map(\.dayKey))
        return Set(visibleDays.map(\.dayKey).filter {
            $0 > scannedThroughKey && !recordedKeys.contains($0)
        })
    }

    private static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func selectedDayKey(
        pinnedDayKey: String?,
        hoveredDayKey: String?,
        detailDayKey: String?,
        availableDayKeys: Set<String>,
        defaultDayKey: String?
    ) -> String? {
        for key in [pinnedDayKey, hoveredDayKey, detailDayKey, defaultDayKey] {
            if let key, availableDayKeys.contains(key) { return key }
        }
        return nil
    }

    static func nextDayKey(
        from currentDayKey: String?,
        direction: Int,
        days: [CostDay]
    ) -> String? {
        guard !days.isEmpty else { return nil }
        let currentIndex = days.firstIndex { $0.dayKey == currentDayKey } ?? (days.count - 1)
        let index = min(days.count - 1, max(0, currentIndex + direction))
        return days[index].dayKey
    }

    static func opacity(dayKey: String, selectedDayKey: String?) -> Double {
        dayKey == selectedDayKey ? 1 : self.restingOpacity
    }

    static func labelText(
        selectedMode: CostChartLabelMode,
        tokens: Int,
        costUSD: Double?
    ) -> String {
        switch selectedMode {
        case .tokens: Formatters.tokens(tokens)
        case .cost: costUSD.map(Formatters.compactCost) ?? "—"
        }
    }

    static func labelText(
        dayKey: String,
        selectedDayKey: String?,
        selectedMode: CostChartLabelMode,
        tokens: Int,
        costUSD: Double?
    ) -> String? {
        guard dayKey == selectedDayKey else { return nil }
        return self.labelText(selectedMode: selectedMode, tokens: tokens, costUSD: costUSD)
    }
}

/// Parent-driven disclosure motion and the view use the same row height.
struct CostBreakdownLayout {
    let summaryHeight: Double
    let rowHeight: Double
    let toggleHeight: Double
    let spacing: Double

    func rowsHeight(rows: Int) -> Double {
        Double(max(0, rows)) * (self.rowHeight + self.spacing)
    }

    func rowsHeight(rows: Int, openness: Double) -> Double {
        (self.rowsHeight(rows: rows) * min(1, max(0, openness))).rounded()
    }

    func height(rows: Int, hasToggle: Bool, openness: Double) -> Double {
        self.summaryHeight + (hasToggle ? self.spacing + self.toggleHeight : 0)
            + self.rowsHeight(rows: rows, openness: openness)
    }
}
