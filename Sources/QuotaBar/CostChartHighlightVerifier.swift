#if DEBUG
import QuotaBarCore
import Foundation
import SwiftUI

enum CostChartHighlightVerifier {
    static func run() -> Never {
        let yesterday = "2026-08-25"
        let today = "2026-08-26"
        let available = Set([yesterday, today])
        var failures: [String] = []

        let previousDay = CostDay(
            dayKey: yesterday,
            byModel: [:],
            costUSD: 17,
            unpricedTokens: 0
        )
        let visibleWithoutToday = CostChartHighlightPolicy.visibleDays(
            from: [previousDay],
            todayDayKey: today,
            maxBars: 10
        )
        if visibleWithoutToday.map(\.dayKey) != [yesterday, today]
            || visibleWithoutToday.last?.costUSD != 0 {
            failures.append("a missing today expected a zero-cost today bar")
        }
        let defaultDetailDayKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: nil,
            currentDayKey: nil,
            availableDayKeys: Set(visibleWithoutToday.map(\.dayKey)),
            defaultDayKey: visibleWithoutToday.last?.dayKey
        )
        if defaultDetailDayKey != today {
            failures.append(
                "an idle chart expected detail for its newest bar, got \(defaultDetailDayKey ?? "nil")"
            )
        }
        let nextDay = "2026-08-27"
        let pinnedBeforeRefresh = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: nil,
            currentDayKey: yesterday,
            availableDayKeys: available,
            defaultDayKey: today
        )
        let fallbackAfterRefresh = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: nil,
            currentDayKey: yesterday,
            availableDayKeys: Set([today, nextDay]),
            defaultDayKey: nextDay
        )
        if pinnedBeforeRefresh != yesterday || fallbackAfterRefresh != nextDay {
            failures.append(
                "detail refresh expected a valid pin to stay and an evicted pin to use the newest "
                    + "bar, got \(pinnedBeforeRefresh ?? "nil")/\(fallbackAfterRefresh ?? "nil")"
            )
        }
        let idleSelection = CostChartHighlightPolicy.selectedDayKey(
            hoveredDayKey: nil,
            availableDayKeys: Set(visibleWithoutToday.map(\.dayKey))
        )
        let idleLabel = CostChartHighlightPolicy.labelText(
            dayKey: today,
            selectedDayKey: idleSelection,
            selectedMode: .tokens,
            tokens: visibleWithoutToday.last?.tokens.total ?? -1,
            costUSD: visibleWithoutToday.last?.costUSD
        )
        if idleSelection != nil || idleLabel != nil {
            failures.append("an idle chart expected no selected bar or value label")
        }

        let todayDay = CostDay(
            dayKey: today,
            byModel: [:],
            costUSD: 23,
            unpricedTokens: 0
        )
        let visibleWithToday = CostChartHighlightPolicy.visibleDays(
            from: [previousDay, todayDay],
            todayDayKey: today,
            maxBars: 10
        )
        if visibleWithToday.map(\.dayKey) != [yesterday, today]
            || visibleWithToday.last?.costUSD != 23 {
            failures.append("an existing today bar was duplicated or replaced")
        }

        let tokenHeavyDay = CostDay(
            dayKey: yesterday,
            byModel: [
                ModelUsageKey(source: .codex, model: "token-heavy"): ModelDayUsage(
                    tokens: TokenTotals(input: 120, output: 80),
                    costUSD: 10
                ),
            ],
            costUSD: 10,
            unpricedTokens: 0
        )
        let costHeavyDay = CostDay(
            dayKey: today,
            byModel: [
                ModelUsageKey(source: .codex, model: "cost-heavy"): ModelDayUsage(
                    tokens: TokenTotals(input: 40, output: 60),
                    costUSD: 20
                ),
            ],
            costUSD: 20,
            unpricedTokens: 0
        )
        let unpricedDay = CostDay(
            dayKey: "2026-08-27",
            byModel: [
                ModelUsageKey(source: .codex, model: "unpriced"): ModelDayUsage(
                    tokens: TokenTotals(input: 7),
                    costUSD: nil
                ),
            ],
            costUSD: nil,
            unpricedTokens: 7
        )
        if CostChartHighlightPolicy.value(for: tokenHeavyDay, mode: .tokens) != 200
            || CostChartHighlightPolicy.value(for: tokenHeavyDay, mode: .cost) != 10 {
            failures.append("chart value expected token and cost metrics from the selected mode")
        }
        if CostChartHighlightPolicy.value(for: unpricedDay, mode: .cost) != 0 {
            failures.append("a missing day cost expected a zero chart value")
        }
        let inverseMetricDays = [tokenHeavyDay, costHeavyDay]
        let tokenMax = CostChartHighlightPolicy.maxValue(for: inverseMetricDays, mode: .tokens)
        let costMax = CostChartHighlightPolicy.maxValue(for: inverseMetricDays, mode: .cost)
        if tokenMax != 200 || costMax != 20 {
            failures.append(
                "chart scale expected token max 200 and cost max 20, got \(tokenMax) and \(costMax)"
            )
        }

        let capped = CostChartHighlightPolicy.visibleDays(
            from: (1...10).map { day in
                CostDay(
                    dayKey: String(format: "2026-08-%02d", day),
                    byModel: [:],
                    costUSD: Double(day),
                    unpricedTokens: 0
                )
            },
            todayDayKey: today,
            maxBars: 10
        )
        if capped.count != 10 || capped.first?.dayKey != "2026-08-02" || capped.last?.dayKey != today {
            failures.append("adding today expected to keep the ten-bar cap and evict the oldest day")
        }

        let idleSelectionWithActivity = CostChartHighlightPolicy.selectedDayKey(
            hoveredDayKey: nil,
            availableDayKeys: available
        )
        if idleSelectionWithActivity != nil {
            failures.append(
                "an idle chart expected no selection, got \(idleSelectionWithActivity ?? "nil")"
            )
        }

        let hoverSelection = CostChartHighlightPolicy.selectedDayKey(
            hoveredDayKey: yesterday,
            availableDayKeys: available
        )
        if hoverSelection != yesterday {
            failures.append("hover selection expected yesterday, got \(hoverSelection ?? "nil")")
        }

        let selectedOpacity = CostChartHighlightPolicy.opacity(dayKey: today, selectedDayKey: today)
        let inactiveOpacity = CostChartHighlightPolicy.opacity(
            dayKey: yesterday,
            selectedDayKey: today
        )
        let idleOpacity = CostChartHighlightPolicy.opacity(dayKey: yesterday, selectedDayKey: nil)
        if selectedOpacity != 1.0
            || inactiveOpacity != CostChartHighlightPolicy.restingOpacity
            || idleOpacity != CostChartHighlightPolicy.restingOpacity
        {
            failures.append(
                "expected the selected bar opaque and every other day at the resting tone, got "
                    + "\(selectedOpacity)/\(inactiveOpacity)/\(idleOpacity)"
            )
        }

        let idleTodayLabel = CostChartHighlightPolicy.labelText(
            dayKey: today,
            selectedDayKey: idleSelectionWithActivity,
            selectedMode: .tokens,
            tokens: 231_000_000,
            costUSD: 231
        )
        if idleTodayLabel != nil {
            failures.append("an idle today bar displayed a label: \(String(describing: idleTodayLabel))")
        }

        let clickedMode = CostChartHighlightPolicy.labelMode(
            afterClicking: yesterday,
            selectedDayKey: hoverSelection,
            currentMode: .tokens
        )
        let hoveredLabel = CostChartHighlightPolicy.labelText(
            dayKey: yesterday,
            selectedDayKey: hoverSelection,
            selectedMode: clickedMode,
            tokens: 17_000_000,
            costUSD: 17
        )
        if hoveredLabel != "$17" {
            failures.append("clicked hovered bar expected its $17 label, got \(String(describing: hoveredLabel))")
        }

        let clickedAgainMode = CostChartHighlightPolicy.labelMode(
            afterClicking: yesterday,
            selectedDayKey: hoverSelection,
            currentMode: clickedMode
        )
        if clickedAgainMode != .tokens {
            failures.append("clicking the selected bar again expected its token label")
        }

        let otherBarLabel = CostChartHighlightPolicy.labelText(
            dayKey: today,
            selectedDayKey: hoverSelection,
            selectedMode: clickedMode,
            tokens: 231_000_000,
            costUSD: 231
        )
        if otherBarLabel != nil {
            failures.append("a non-hovered bar displayed a label")
        }

        let zeroCostLabel = CostChartHighlightPolicy.labelText(
            dayKey: yesterday,
            selectedDayKey: hoverSelection,
            selectedMode: .cost,
            tokens: 0,
            costUSD: nil
        )
        if zeroCostLabel != "$0.00" {
            failures.append("a selected day with missing cost data expected $0.00")
        }

        let ignoredClickMode = CostChartHighlightPolicy.labelMode(
            afterClicking: today,
            selectedDayKey: hoverSelection,
            currentMode: .tokens
        )
        if ignoredClickMode != .tokens {
            failures.append("clicking a non-selected bar changed the selected label mode")
        }

        let nextBarLabel = CostChartHighlightPolicy.labelText(
            dayKey: today,
            selectedDayKey: today,
            selectedMode: clickedMode,
            tokens: 231_000_000,
            costUSD: 231
        )
        if nextBarLabel != "$231" {
            failures.append("moving to another selected bar forgot the cost label mode")
        }

        let firstBar = CostChartHighlightPolicy.barIndex(atX: 47, width: 100, barCount: 2, spacing: 4)
        let gap = CostChartHighlightPolicy.barIndex(atX: 49, width: 100, barCount: 2, spacing: 4)
        let secondBar = CostChartHighlightPolicy.barIndex(atX: 53, width: 100, barCount: 2, spacing: 4)
        if firstBar != 0 || gap != nil || secondBar != 1 {
            failures.append(
                "bar hit testing expected 0/nil/1 across a gap, got "
                    + "\(String(describing: firstBar))/\(String(describing: gap))/"
                    + "\(String(describing: secondBar))"
            )
        }

        // The highlight's motion: a move between bars keeps up with the pointer, clearing it takes
        // longer, and Reduce Motion drops both rather than shortening them.
        if CostChartHoverMotion.clearResponse <= CostChartHoverMotion.hoverResponse {
            failures.append(
                "clearing hover expected a longer response than moving between bars, got "
                    + "\(CostChartHoverMotion.clearResponse) vs \(CostChartHoverMotion.hoverResponse)"
            )
        }
        // The highlight's shape is a mark under the baseline, not a change to the bar: a bar the
        // reader is comparing by height cannot change height under the pointer.
        if CostChartHoverMotion.markerHeight <= 0 || CostChartHoverMotion.markerGap <= 0 {
            failures.append(
                "the selected bar expected a mark below it, got \(CostChartHoverMotion.markerHeight)"
                    + " thick at \(CostChartHoverMotion.markerGap) below the baseline"
            )
        }
        let markerWidths = [0.0, 0.5, 1.0].map(CostChartHoverMotion.markerWidth)
        if markerWidths.last != 1 || markerWidths[0] <= 0 || markerWidths[0] >= markerWidths[1]
            || markerWidths[1] >= markerWidths[2] {
            failures.append(
                "the mark expected to open from a stub to the bar's full width, got \(markerWidths)"
            )
        }
        if CostChartHoverMotion.markerWidth(share: -1) != CostChartHoverMotion.markerWidth(share: 0)
            || CostChartHoverMotion.markerWidth(share: 2) != 1 {
            failures.append("the mark's width expected to clamp outside the crossover")
        }
        let hoverMotion = CostChartHoverMotion.animation(clearingHover: false, reduceMotion: false)
        let clearMotion = CostChartHoverMotion.animation(clearingHover: true, reduceMotion: false)
        if hoverMotion == nil || clearMotion == nil || hoverMotion == clearMotion {
            failures.append("hover and clear expected two distinct animations")
        }
        let reducedHover = CostChartHoverMotion.animation(clearingHover: false, reduceMotion: true)
        let reducedClear = CostChartHoverMotion.animation(clearingHover: true, reduceMotion: true)
        if reducedHover != nil || reducedClear != nil {
            failures.append("Reduce Motion expected no animation on either move")
        }

        // Opening the list is the slowest change on the card: the rows fade rather than cut, and
        // they take longer over it than the highlight takes to cross the chart.
        if CostChartHoverMotion.breakdownDuration <= CostChartHoverMotion.clearResponse {
            failures.append(
                "opening the breakdown expected to outlast the highlight's trip home, got "
                    + "\(CostChartHoverMotion.breakdownDuration) vs \(CostChartHoverMotion.clearResponse)"
            )
        }
        // Its curve is stepped by hand rather than handed to an animator, so the shape itself is
        // what gets checked: it starts at rest, ends at rest, and only ever moves forward.
        let ease = stride(from: 0.0, through: 1.0, by: 0.05).map(CostChartHoverMotion.breakdownEase)
        if ease.first != 0 || ease.last != 1 {
            failures.append("the reveal's curve expected to run from 0 to 1, got \(ease)")
        }
        if zip(ease, ease.dropFirst()).contains(where: { $0 >= $1 }) {
            failures.append("the reveal's curve expected to rise at every step, got \(ease)")
        }
        if CostChartHoverMotion.breakdownEase(0.5) != 0.5 {
            failures.append(
                "the reveal's curve expected to ease in and out alike, got "
                    + "\(CostChartHoverMotion.breakdownEase(0.5)) at halfway"
            )
        }
        if CostChartHoverMotion.breakdownEase(-1) != 0 || CostChartHoverMotion.breakdownEase(2) != 1 {
            failures.append("the reveal's curve expected to clamp outside its own beat")
        }

        // The unit swap: the label resolves rather than cuts, it stays in place while it does,
        // and Reduce Motion drops the resolve rather than shortening it.
        if CostChartHoverMotion.swapDuration <= 0 {
            failures.append(
                "the unit swap expected a duration, got \(CostChartHoverMotion.swapDuration)"
            )
        }
        if CostChartHoverMotion.swapBlur <= 0 || CostChartHoverMotion.swapScale >= 1 {
            failures.append(
                "the unit swap expected to blur and undersize the outgoing number, got "
                    + "\(CostChartHoverMotion.swapBlur)/\(CostChartHoverMotion.swapScale)"
            )
        }
        let swapMotion = CostChartHoverMotion.swapAnimation(reduceMotion: false)
        if swapMotion == nil || swapMotion == hoverMotion {
            failures.append("the unit swap expected an animation of its own, distinct from a hover")
        }
        if CostChartHoverMotion.swapAnimation(reduceMotion: true) != nil {
            failures.append("Reduce Motion expected no animation on the unit swap")
        }

        // The breakdown block: what it reserves, where the row that opens it sits, and what the
        // pointer is over. Round numbers rather than the card's own, so the checks read the
        // arithmetic instead of restating the constants.
        let layout = CostBreakdownLayout(summaryHeight: 10, rowHeight: 10, toggleHeight: 10, spacing: 2)
        if layout.height(rows: 0, hasToggle: false) != 10 {
            failures.append("a breakdown with no models expected its summary line alone")
        }
        if layout.height(rows: 2, hasToggle: false) != 34 || layout.height(rows: 2, hasToggle: true) != 46 {
            failures.append(
                "breakdown height expected 34 without the toggle row and 46 with it, got "
                    + "\(layout.height(rows: 2, hasToggle: false)) and \(layout.height(rows: 2, hasToggle: true))"
            )
        }
        if layout.rowsHeight(rows: 3) != 36 || layout.rowsHeight(rows: 0) != 0 {
            failures.append(
                "the rows strip expected each row to carry its own gap, got \(layout.rowsHeight(rows: 3))"
            )
        }
        // The reveal lands on whole points at every step, however far open it is: the lines under
        // the strip are laid out from its edge, and a fraction there is where text shimmers.
        let openSteps = stride(from: 0.0, through: 1.0, by: 0.05).map {
            layout.rowsHeight(rows: 2, openness: $0)
        }
        if openSteps.contains(where: { $0 != $0.rounded() }) {
            failures.append("the reveal expected whole points at every step, got \(openSteps)")
        }
        if openSteps.first != 0 || openSteps.last != layout.rowsHeight(rows: 2) {
            failures.append("the reveal expected to run from nothing to the rows' full height")
        }
        if zip(openSteps, openSteps.dropFirst()).contains(where: { $0 > $1 }) {
            failures.append("the reveal expected to open without going backwards")
        }
        if layout.toggleBand(rows: 2, hasToggle: false) != nil {
            failures.append("a day that fits expected no toggle row")
        }
        let collapsedBand = layout.toggleBand(rows: 2, hasToggle: true)
        let expandedBand = layout.toggleBand(rows: 5, hasToggle: true)
        if collapsedBand != 36...46 {
            failures.append("collapsed toggle row expected 36...46, got \(String(describing: collapsedBand))")
        }
        if let collapsedBand, let expandedBand, expandedBand.lowerBound <= collapsedBand.upperBound {
            failures.append("opening the list expected the toggle row to move below the rows it added")
        }

        // One tracking area covers the chart and the breakdown, so the hit test has to say which
        // of them a point is in: a click under the chart must not swap the chart's unit, and the
        // walk down to the toggle row must not read as a bar.
        let chartBand: Double = 75
        let detailTop: Double = 85
        func region(
            _ x: Double,
            _ y: Double,
            barHeights: [Double] = [10, 56],
            labelSizes: [CGSize?] = [nil, nil],
            toggleBand: ClosedRange<Double>? = collapsedBand
        ) -> CostChartHighlightPolicy.Region {
            CostChartHighlightPolicy.region(
                at: CGPoint(x: x, y: y),
                width: 100,
                chartBottom: chartBand,
                barHeights: barHeights,
                labelSizes: labelSizes,
                labelOffsetY: -14,
                spacing: 4,
                detailTop: detailTop,
                toggleBand: toggleBand
            )
        }
        if region(47, 70) != .bar(0) || region(53, 30) != .bar(1) {
            failures.append("a point on a bar expected that bar, got \(region(47, 70)) and \(region(53, 30))")
        }
        if region(47, 30) != .elsewhere {
            failures.append("a point above a short bar expected no region, got \(region(47, 30))")
        }
        if region(49, 30) != .elsewhere {
            failures.append("the gap between two bars expected no region, got \(region(49, 30))")
        }
        if region(47, detailTop + 40) != .breakdownToggle {
            failures.append("a point on the toggle row expected it, got \(region(47, detailTop + 40))")
        }
        if region(47, detailTop + 5) != .elsewhere || region(47, detailTop + 60) != .elsewhere {
            failures.append("a point on a model row, or past the block, expected no region")
        }
        let detailRegion = region(47, detailTop + 5)
        if detailRegion == .bar(0) {
            failures.append("a point in the detail area expected not to count as a bar")
        }
        let keyInDetail: String?
        if case let .bar(index) = detailRegion {
            keyInDetail = [yesterday, today][index]
        } else {
            keyInDetail = nil
        }
        if keyInDetail != nil {
            failures.append(
                "moving into the detail area expected hover to clear, got "
                    + "\(keyInDetail ?? "nil")"
            )
        }

        // Drive one interaction through repeated hit tests. The bar label is transient, while
        // detail starts on the newest bar and only another bar hover can replace it. Keeping those
        // states separate leaves the toggle in the next render and lets the click land on it.
        func dayKey(for region: CostChartHighlightPolicy.Region) -> String? {
            switch region {
            case let .bar(index), let .label(index):
                return [yesterday, today][index]
            case .breakdownToggle, .elsewhere:
                return nil
            }
        }
        var labelSequenceHoveredDayKey = dayKey(for: region(24, 70))
        let selectedLabelSizes: [CGSize?] = [CGSize(width: 24, height: 12), nil]
        let bridgeRegion = region(
            24,
            59,
            barHeights: [15, 56],
            labelSizes: selectedLabelSizes
        )
        labelSequenceHoveredDayKey = dayKey(for: bridgeRegion)
        let labelSizesAfterBridge = labelSequenceHoveredDayKey == nil
            ? [CGSize?](repeating: nil, count: 2)
            : selectedLabelSizes
        let labelRegion = region(
            24,
            52,
            barHeights: [15, 56],
            labelSizes: labelSizesAfterBridge
        )
        let aboveVisibleLabel = region(
            24,
            30,
            barHeights: [15, 56],
            labelSizes: selectedLabelSizes
        )
        let labelDayKey = dayKey(for: labelRegion)
        labelSequenceHoveredDayKey = labelDayKey
        let labelClickMode = labelDayKey.map {
            CostChartHighlightPolicy.labelMode(
                afterClicking: $0,
                selectedDayKey: labelSequenceHoveredDayKey,
                currentMode: .tokens
            )
        } ?? .tokens
        if bridgeRegion != .label(0) || labelRegion != .label(0)
            || aboveVisibleLabel != .elsewhere
            || labelSequenceHoveredDayKey != yesterday
            || labelClickMode != .cost {
            failures.append(
                "bar-to-label sequence expected a bridged gap, label(0), empty space above it, "
                    + "retained hover, and a cost click; got \(bridgeRegion)/\(labelRegion)/"
                    + "\(aboveVisibleLabel)/"
                    + "\(labelSequenceHoveredDayKey ?? "nil")/\(labelClickMode)"
            )
        }
        let initialDayKey = dayKey(for: region(47, 70))
        var sequenceHoveredDayKey = initialDayKey
        var sequenceDetailDayKey = defaultDetailDayKey
        sequenceDetailDayKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: initialDayKey,
            currentDayKey: sequenceDetailDayKey,
            availableDayKeys: available,
            defaultDayKey: today
        )
        let aboveShortBarDayKey = dayKey(for: region(47, 30))
        sequenceHoveredDayKey = aboveShortBarDayKey
        sequenceDetailDayKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: aboveShortBarDayKey,
            currentDayKey: sequenceDetailDayKey,
            availableDayKeys: available,
            defaultDayKey: today
        )
        let modelRowDayKey = dayKey(for: region(47, detailTop + 5))
        sequenceHoveredDayKey = modelRowDayKey
        sequenceDetailDayKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: modelRowDayKey,
            currentDayKey: sequenceDetailDayKey,
            availableDayKeys: available,
            defaultDayKey: today
        )
        let sequenceToggleBand = sequenceDetailDayKey == nil ? nil : collapsedBand
        let sequenceToggle = region(47, detailTop + 40, toggleBand: sequenceToggleBand)
        var sequenceExpanded = false
        if sequenceToggle == .breakdownToggle { sequenceExpanded.toggle() }
        let detailAfterExit = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: nil,
            currentDayKey: sequenceDetailDayKey,
            availableDayKeys: available,
            defaultDayKey: today
        )
        let detailAfterNextBar = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: today,
            currentDayKey: detailAfterExit,
            availableDayKeys: available,
            defaultDayKey: today
        )
        if sequenceHoveredDayKey != nil || sequenceDetailDayKey != yesterday
            || sequenceToggle != .breakdownToggle || !sequenceExpanded
            || detailAfterExit != yesterday || detailAfterNextBar != today {
            failures.append(
                "bar-to-detail sequence expected nil hover, retained detail, a clickable toggle, "
                    + "retained exit, and replacement by the next bar; got "
                    + "\(sequenceHoveredDayKey ?? "nil")/\(sequenceDetailDayKey ?? "nil")/"
                    + "\(sequenceToggle)/\(sequenceExpanded)/\(detailAfterExit ?? "nil")/"
                    + "\(detailAfterNextBar ?? "nil")"
            )
        }

        VerifierReport.finish(
            failures,
            label: "cost chart highlight verification",
            passed: "cost chart selection, persistent detail, click label toggle, hit testing, "
                + "opacity, hover motion, unit swap motion, and expandable breakdown layout checks passed"
        )
    }
}
#endif
