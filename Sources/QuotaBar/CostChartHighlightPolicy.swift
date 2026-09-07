import QuotaBarCore
import CoreGraphics

enum CostChartHighlightPolicy {
    /// The chart's height metric follows the label unit selected by the reader.
    static func value(for day: CostDay, mode: CostChartLabelMode) -> Double {
        switch mode {
        case .tokens:
            return Double(day.tokens.total)
        case .cost:
            return day.costUSD ?? 0
        }
    }

    /// The scale uses the same metric as each bar, so switching units rescales the whole chart.
    static func maxValue(for days: [CostDay], mode: CostChartLabelMode) -> Double {
        days.map { Self.value(for: $0, mode: mode) }.max() ?? 0
    }

    static func visibleDays(
        from days: [CostDay],
        todayDayKey: String,
        maxBars: Int
    ) -> [CostDay] {
        guard maxBars > 0 else { return [] }

        var visible = Array(days.suffix(maxBars))
        guard !visible.contains(where: { $0.dayKey == todayDayKey }) else { return visible }

        if visible.count == maxBars {
            visible.removeFirst()
        }
        visible.append(CostDay(
            dayKey: todayDayKey,
            byModel: [:],
            costUSD: 0,
            unpricedTokens: 0
        ))
        visible.sort { $0.dayKey < $1.dayKey }
        return visible
    }

    static func selectedDayKey(
        hoveredDayKey: String?,
        availableDayKeys: Set<String>
    ) -> String? {
        guard let hoveredDayKey, availableDayKeys.contains(hoveredDayKey) else { return nil }
        return hoveredDayKey
    }

    /// Detail keeps a valid pinned bar, takes a new hover, or falls back to the newest current bar.
    static func detailDayKey(
        afterMovingTo dayKey: String?,
        currentDayKey: String?,
        availableDayKeys: Set<String>,
        defaultDayKey: String?
    ) -> String? {
        if let dayKey, availableDayKeys.contains(dayKey) { return dayKey }
        if let currentDayKey, availableDayKeys.contains(currentDayKey) { return currentDayKey }
        guard let defaultDayKey, availableDayKeys.contains(defaultDayKey) else { return nil }
        return defaultDayKey
    }

    /// The one quiet tone every unselected day shares.
    static let restingOpacity = 0.55

    static func opacity(dayKey: String, selectedDayKey: String?) -> Double {
        dayKey == selectedDayKey ? 1.0 : Self.restingOpacity
    }

    /// What one day's label reads. Token count is the default; cost mode still renders missing
    /// cost data as zero so a zero-height day never loses its label.
    static func labelText(
        selectedMode: CostChartLabelMode,
        tokens: Int,
        costUSD: Double?
    ) -> String {
        switch selectedMode {
        case .tokens:
            return Formatters.tokens(tokens)
        case .cost:
            return Formatters.compactCost(costUSD ?? 0)
        }
    }

    /// Only the selected bar has a label, for a caller that has not already established which bar
    /// it is holding.
    static func labelText(
        dayKey: String,
        selectedDayKey: String?,
        selectedMode: CostChartLabelMode,
        tokens: Int,
        costUSD: Double?
    ) -> String? {
        guard dayKey == selectedDayKey else { return nil }
        return Self.labelText(selectedMode: selectedMode, tokens: tokens, costUSD: costUSD)
    }

    static func labelMode(
        afterClicking dayKey: String?,
        selectedDayKey: String?,
        currentMode: CostChartLabelMode
    ) -> CostChartLabelMode {
        guard let dayKey, dayKey == selectedDayKey else { return currentMode }
        return currentMode == .tokens ? .cost : .tokens
    }

    /// Mirrors the HStack's equal-width bars and explicit spacing. Pointer movement through a gap
    /// clears the hover instead of borrowing the bar on either side.
    static func barIndex(atX x: Double, width: Double, barCount: Int, spacing: Double) -> Int? {
        guard barCount > 0, width > 0, spacing >= 0, x >= 0, x <= width else { return nil }
        let totalSpacing = spacing * Double(barCount - 1)
        let barWidth = (width - totalSpacing) / Double(barCount)
        guard barWidth > 0 else { return nil }

        let slotWidth = barWidth + spacing
        let index = min(barCount - 1, Int(x / slotWidth))
        let offset = x - Double(index) * slotWidth
        return offset <= barWidth ? index : nil
    }

    /// What the pointer is over inside the chart-plus-breakdown block. Any point outside a bar or
    /// its selected label clears the chart hover.
    enum Region: Equatable {
        case bar(Int)
        case label(Int)
        case breakdownToggle
        case elsewhere
    }

    /// `chartBottom` is the bottom of every bar, measured from the tracking area's origin.
    /// `barHeights` are the rendered heights in horizontal order. A non-nil `labelSize` keeps the
    /// text's exact horizontal span and bridges its vertical hit rect down to the selected bar.
    /// `toggleBand` is measured from `detailTop`, which is what `CostBreakdownLayout` returns.
    static func region(
        at point: CGPoint,
        width: Double,
        chartBottom: Double,
        barHeights: [Double],
        labelSizes: [CGSize?],
        labelOffsetY: Double,
        spacing: Double,
        detailTop: Double,
        toggleBand: ClosedRange<Double>?
    ) -> Region {
        guard point.y >= 0, point.x >= 0, point.x <= width else { return .elsewhere }
        let totalSpacing = spacing * Double(max(0, barHeights.count - 1))
        let barWidth = (width - totalSpacing) / Double(max(1, barHeights.count))
        if barWidth > 0 {
            let slotWidth = barWidth + spacing
            for index in barHeights.indices {
                guard labelSizes.indices.contains(index), let size = labelSizes[index] else { continue }
                let labelLeft = Double(index) * slotWidth + (barWidth - size.width) / 2
                let barTop = chartBottom - max(0, barHeights[index])
                let labelTop = barTop + labelOffsetY
                let labelBottom = max(labelTop + size.height, barTop)
                if point.x >= labelLeft, point.x <= labelLeft + size.width,
                   point.y >= labelTop, point.y <= labelBottom {
                    return .label(index)
                }
            }
        }
        if point.y <= chartBottom,
           let index = Self.barIndex(
               atX: point.x,
               width: width,
               barCount: barHeights.count,
               spacing: spacing
           ),
           point.y >= chartBottom - max(0, barHeights[index]) {
            return .bar(index)
        }
        guard let toggleBand, toggleBand.contains(point.y - detailTop) else { return .elsewhere }
        return .breakdownToggle
    }
}

/// The vertical metrics of the breakdown block under the chart: one summary line, a model row per
/// entry, and the row that opens or closes the models that did not fit. The view lays the block
/// out from these and the pointer is hit-tested against them, so the two readings cannot drift.
struct CostBreakdownLayout {
    let summaryHeight: Double
    let rowHeight: Double
    let toggleHeight: Double
    let spacing: Double

    func height(rows: Int, hasToggle: Bool) -> Double {
        var height = self.summaryHeight + self.rowsHeight(rows: rows)
        if hasToggle { height += self.spacing + self.toggleHeight }
        return height
    }

    /// The strip `rows` model rows occupy. Each row carries the gap above it rather than leaving
    /// it to the stack, so a row that closes takes its gap with it instead of leaving a seam.
    func rowsHeight(rows: Int) -> Double {
        Double(max(0, rows)) * (self.rowHeight + self.spacing)
    }

    /// The strip those rows occupy while the list is `openness` of the way open, in whole points.
    /// A strip on a fraction of a point puts every line under it on a fraction of a pixel, and
    /// text there shimmers rather than slides.
    func rowsHeight(rows: Int, openness: Double) -> Double {
        (self.rowsHeight(rows: rows) * min(1, max(0, openness))).rounded()
    }

    /// Where the toggle row sits, measured down from the top of the block. Nil when the day on
    /// screen fits without one. It follows the rows above it, so opening the list moves the row
    /// that closes it back down under the last model.
    func toggleBand(rows: Int, hasToggle: Bool) -> ClosedRange<Double>? {
        guard hasToggle else { return nil }
        let top = self.height(rows: rows, hasToggle: false) + self.spacing
        return top...(top + self.toggleHeight)
    }
}
