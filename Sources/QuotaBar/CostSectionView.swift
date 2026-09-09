import AppKit
import QuotaBarCore
import SwiftUI

/// The cost half of the popover: a KPI grid, the per-day bar chart, the top model, and the
/// estimate disclaimer.
struct CostSectionView: View {
    let snapshot: CostSnapshot

    /// The chart stays readable at card width; older days fall off the left.
    private static let maxBars = 10
    private static let chartHeight: CGFloat = 56
    private static let barSpacing: CGFloat = 4
    private static let labelOffsetY: CGFloat = -14
    /// Room for the selected bar's label, so neither the card nor the KPI row above it moves when
    /// the highlight changes bars.
    private static let chartTopPadding = -Self.labelOffsetY
    /// Four covers a normal day for either provider; the rest collapse behind a "+N more" line
    /// the reader can open.
    private static let maxBreakdownRows = 4
    static let breakdownLayout = CostBreakdownLayout(
        summaryHeight: 60,
        rowHeight: 13,
        toggleHeight: 12,
        spacing: 7
    )
    /// The gap between the chart and the breakdown under it, and the one the card's own stack
    /// puts between every section. Both are the same 10 pt, and the pointer is read against the
    /// first of them.
    private static let sectionSpacing: CGFloat = 10
    /// The rank bar and the gap after it. Together they are the column every breakdown line
    /// starts its text at, the toggle row's chevron included.
    private static let breakdownBarWidth: CGFloat = 2
    private static let breakdownMarkerGap: CGFloat = 6
    private static let breakdownMarkerWidth = Self.breakdownBarWidth + Self.breakdownMarkerGap

    /// Which day the pointer is over. Nil leaves every bar unselected.
    @State private var hoveredDayKey: String?
    /// The newest day starts here; a later bar hover replaces it until another does or it expires.
    @State private var detailDayKey: String?
    /// Updated immediately on click, then seeded from SettingsStore whenever the card is rebuilt.
    @State private var selectedLabelMode: CostChartLabelMode
    /// Whether the "+N more" line is pointed at, which is the whole of what says it is a switch.
    @State private var isToggleHovered = false
    private let onLabelModeChanged: (CostChartLabelMode) -> Void
    /// Opening the day's full model list makes the card taller, and the card's height belongs to
    /// the menu hosting it -- so unlike the label unit, this one is owned by the caller and comes
    /// back down as a new value rather than living in `@State` here.
    private let isBreakdownExpanded: Bool
    /// How far open the list is drawn right now, 0 to 1. The caller steps it: the card's height is
    /// an AppKit frame and the rows are SwiftUI, and the two only stay together if one clock moves
    /// both. Nothing here animates on its own.
    private let breakdownOpenness: Double
    /// The day whose full list is open. The menu owns this key so its off-screen height probe
    /// measures the same day as the live card instead of falling back to the latest bar.
    private let expandedBreakdownDayKey: String?
    private let onBreakdownExpandedChanged: (Bool, String?) -> Void

    /// Activity days plus an empty today bar, so today's cost remains visible before the first
    /// completed turn. Older activity falls off the left once the chart reaches its cap. The
    /// snapshot and today's key are both fixed for the life of the view, so the chart's shape is
    /// settled here rather than rebuilt on every read — hover moves at pointer rate.
    private let bars: [CostDay]
    private let barDayKeys: Set<String>
    private let todayTokens: Int

    /// Seeds the hover state so `--dump-card` can capture what hovering looks like.
    init(
        snapshot: CostSnapshot,
        previewHoveredDayKey: String? = nil,
        previewTodayDayKey: String? = nil,
        labelMode: CostChartLabelMode = .tokens,
        onLabelModeChanged: @escaping (CostChartLabelMode) -> Void = { _ in },
        isBreakdownExpanded: Bool = false,
        breakdownOpenness: Double? = nil,
        expandedBreakdownDayKey: String? = nil,
        previewToggleHovered: Bool = false,
        onBreakdownExpandedChanged: @escaping (Bool, String?) -> Void = { _, _ in }
    ) {
        let todayDayKey = previewTodayDayKey ?? Formatters.dayKey(for: Date())
        let bars = CostChartHighlightPolicy.visibleDays(
            from: snapshot.days,
            todayDayKey: todayDayKey,
            maxBars: Self.maxBars
        )
        let detailDayKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: previewHoveredDayKey,
            currentDayKey: nil,
            availableDayKeys: Set(bars.map(\.dayKey)),
            defaultDayKey: bars.last?.dayKey
        )

        self.snapshot = snapshot
        self.todayTokens = snapshot.days.first { $0.dayKey == todayDayKey }?.tokens.total ?? 0
        self._hoveredDayKey = State(initialValue: previewHoveredDayKey)
        self._detailDayKey = State(initialValue: detailDayKey)
        self._selectedLabelMode = State(initialValue: labelMode)
        self._isToggleHovered = State(initialValue: previewToggleHovered)
        self.onLabelModeChanged = onLabelModeChanged
        self.isBreakdownExpanded = isBreakdownExpanded
        self.breakdownOpenness = breakdownOpenness ?? (isBreakdownExpanded ? 1 : 0)
        self.expandedBreakdownDayKey = expandedBreakdownDayKey
        self.onBreakdownExpandedChanged = onBreakdownExpandedChanged

        self.bars = bars
        self.barDayKeys = Set(bars.map(\.dayKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            self.kpiGrid
            // Chart and breakdown share one tracking area. The bar highlight can clear while its
            // detail remains available for reading and opening.
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if !self.bars.isEmpty {
                    self.chart
                }
                self.hoverDetail
            }
            .mouseLocation(onMoved: self.updateHover, onClicked: self.handleClick)

            Text("Top model: \(self.topModel ?? "—")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(self.disclaimer)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - KPIs

    private var kpiGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                switch self.selectedLabelMode {
                case .cost:
                    self.kpi(label: "Today", value: Formatters.cost(self.snapshot.todayCostUSD))
                    self.kpi(label: self.windowCostLabel, value: Formatters.cost(self.snapshot.windowCostUSD))
                case .tokens:
                    self.kpi(label: "Today tokens", value: Formatters.tokens(self.todayTokens))
                    self.kpi(label: "30d tokens", value: Formatters.tokens(self.snapshot.windowTokens))
                }
            }
        }
    }

    /// Codex labels the window plainly; Claude spells out that the figure is a cost.
    private var windowCostLabel: String {
        self.snapshot.provider == .codex ? "30d" : "30d cost"
    }

    private func kpi(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
        }
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private var chart: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            // Hoisted: `bar(for:)` needs it for every bar, and it walks the whole day list.
            let maxValue = self.maxValue
            ForEach(self.bars, id: \.dayKey) { day in
                self.bar(for: day, maxValue: maxValue)
            }
        }
        .frame(height: Self.chartHeight)
        .padding(.top, Self.chartTopPadding)
        // The mark under the selected bar is drawn outside the bars, so the band it needs is
        // reserved here rather than taken out of the gap to the day's detail.
        .padding(.bottom, CostChartHoverMotion.markerBand)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func bar(for day: CostDay, maxValue: Double) -> some View {
        let value = CostChartHighlightPolicy.value(for: day, mode: self.selectedLabelMode)
        let ratio = maxValue > 0 ? value / maxValue : 0
        let selectedDayKey = self.selectedDayKey
        // Exactly one selected bar is fully opaque; every other day shares one quiet tone.
        let opacity = CostChartHighlightPolicy.opacity(
            dayKey: day.dayKey,
            selectedDayKey: selectedDayKey
        )
        let isSelected = day.dayKey == selectedDayKey
        return RoundedRectangle(cornerRadius: 2)
            .fill(Theme.accent(for: self.snapshot.provider))
            // Opacity as a modifier rather than folded into the fill, so the tone change is a
            // plain animatable value.
            .opacity(opacity)
            // A day with a trace of spend still deserves a visible sliver. Height is the day's
            // own quantity and nothing else: the highlight is the tone plus the mark below.
            .frame(height: self.barHeight(valueRatio: ratio))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { self.marker(isSelected: isSelected) }
            .overlay(alignment: .top) {
                if isSelected {
                    self.label(for: day)
                        .offset(y: Self.labelOffsetY)
                        .transition(CostChartHoverMotion.labelTransition)
                }
            }
    }

    private var maxValue: Double {
        CostChartHighlightPolicy.maxValue(for: self.bars, mode: self.selectedLabelMode)
    }

    private func barHeight(valueRatio: Double) -> CGFloat {
        max(4, Self.chartHeight * valueRatio)
    }

    /// The mark that says which bar the reading belongs to, under the shared baseline where it has
    /// no height to distort. Every bar carries one; an unselected bar's is closed to a stub and
    /// invisible, so the pair on either side of a move opens and closes on the same spring instead
    /// of appearing and disappearing.
    private func marker(isSelected: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(Theme.accent(for: self.snapshot.provider))
            .frame(height: CostChartHoverMotion.markerHeight)
            .scaleEffect(x: CostChartHoverMotion.markerWidth(share: isSelected ? 1 : 0), y: 1)
            .opacity(isSelected ? 1 : 0)
            .offset(y: CostChartHoverMotion.markerBand)
    }

    private func labelSize(for day: CostDay) -> CGSize {
        let text = CostChartHighlightPolicy.labelText(
            selectedMode: self.selectedLabelMode,
            tokens: day.tokens.total,
            costUSD: day.costUSD
        )
        return (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ])
    }

    /// The outer `if` above owns the label's arrival on a bar; this one owns the unit swap on a
    /// bar that already has a label. Keeping the two changes on separate views is what stops a
    /// click from replaying the arrival, or a move between bars from replaying the swap.
    private func label(for day: CostDay) -> some View {
        ZStack {
            ForEach([self.selectedLabelMode], id: \.self) { mode in
                Text(CostChartHighlightPolicy.labelText(
                    selectedMode: mode,
                    tokens: day.tokens.total,
                    costUSD: day.costUSD
                ))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize()
                .transition(CostChartHoverMotion.swapTransition)
            }
        }
    }

    // MARK: - Hover

    private var topModel: String? {
        let day = self.bars.first { $0.dayKey == self.selectedDayKey } ?? self.detailDay
        return day?.rankedModels(by: self.selectedLabelMode).first?.model
    }

    private var detailDay: CostDay? {
        let key = self.validExpandedBreakdownDayKey ?? CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: nil,
            currentDayKey: self.detailDayKey,
            availableDayKeys: self.barDayKeys,
            defaultDayKey: self.bars.last?.dayKey
        )
        guard let key else { return nil }
        return self.bars.first { $0.dayKey == key }
    }

    /// A provider switch or refresh can replace the visible dates while the menu remains open.
    /// Falling back keeps the detail and its close control available instead of holding a stale key.
    private var validExpandedBreakdownDayKey: String? {
        guard let key = self.expandedBreakdownDayKey, self.barDayKeys.contains(key) else { return nil }
        return key
    }

    /// Summary line plus the per-model split, because a day is usually several models -- a
    /// Codex day mixes sol, terra and luna; a Claude day mixes opus, sonnet and haiku.
    /// The block is a fixed height so the card does not resize under the pointer.
    private var hoverDetail: some View {
        // Each line carries the gap above it rather than leaving it to the stack: the rows that
        // open and close have to take their gap with them, or closing one would leave its seam.
        VStack(alignment: .leading, spacing: 0) {
            self.daySummary
                // The summary includes the separator and its lower inset. Keeping this entire
                // header in the layout metrics also keeps the toggle's hit region aligned.
                .frame(height: CGFloat(Self.breakdownLayout.summaryHeight), alignment: .top)

            if let day = self.detailDay {
                let ranked = day.rankedModels(by: self.selectedLabelMode)
                ForEach(Array(ranked.prefix(Self.maxBreakdownRows).enumerated()), id: \.element.key) {
                    index, entry in
                    self.breakdownLine(entry: entry, index: index)
                }
                self.breakdownOverflow(ranked: ranked)
                if self.hasBreakdownToggle {
                    self.breakdownToggleRow(hiddenCount: max(0, ranked.count - Self.maxBreakdownRows))
                }
            }
        }
        .frame(height: self.hoverDetailHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The models that did not fit, in a strip whose height is the reveal: zero closed, their full
    /// height open, and whole points in between. They are always built, so opening and closing are
    /// the same two values moving -- the strip's height and the rows' opacity.
    private func breakdownOverflow(
        ranked: [(key: ModelUsageKey, model: String, usage: ModelDayUsage)]
    ) -> some View {
        let overflow = Array(ranked.dropFirst(Self.maxBreakdownRows).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(overflow, id: \.element.key) { index, entry in
                self.breakdownLine(entry: entry, index: index + Self.maxBreakdownRows)
            }
        }
        .frame(height: self.overflowStripHeight(rows: overflow.count), alignment: .top)
        .clipped()
        .opacity(self.breakdownOpenness)
    }

    private func overflowStripHeight(rows: Int) -> CGFloat {
        CGFloat(Self.breakdownLayout.rowsHeight(rows: rows, openness: self.breakdownOpenness))
    }

    private func breakdownLine(
        entry: (key: ModelUsageKey, model: String, usage: ModelDayUsage),
        index: Int
    ) -> some View {
        self.breakdownRow(
            source: entry.key.source,
            model: entry.model,
            isFast: entry.key.isFast,
            usage: entry.usage,
            index: index
        )
        .padding(.top, CGFloat(Self.breakdownLayout.spacing))
    }

    /// Closed cards reserve the busiest day's compact block so hovering never resizes the menu.
    /// Once opened, only the selected day's hidden rows belong in that block; using the busiest
    /// day's overflow leaves blank space between "Show less" and the next section.
    private var hoverDetailHeight: CGFloat {
        let busiest = self.bars.map(\.byModel.count).max() ?? 0
        let hasToggle = busiest > Self.maxBreakdownRows
        let closed = Self.breakdownLayout.height(
            rows: min(busiest, Self.maxBreakdownRows),
            hasToggle: hasToggle
        )
        let selectedCount = self.detailDay?.byModel.count ?? 0
        return CGFloat(closed) + self.overflowStripHeight(
            rows: max(0, selectedCount - Self.maxBreakdownRows)
        )
    }

    /// How many model rows are above the toggle row, and how much strip is open under them --
    /// both read off what is on screen, so a click lands on the row the pointer is over even
    /// mid-sweep.
    private var visibleBreakdownRows: Int {
        min(self.detailDay?.byModel.count ?? 0, Self.maxBreakdownRows)
    }

    /// The toggle row appears on a day with more models than fit, and stays for as long as the
    /// list is open -- including on a day that would have fit -- so the way back is never missing.
    /// The height reserved above already counts it: only a chart holding such a day can open one.
    /// The toggle row sits under the four rows that always show plus however much of the strip is
    /// open.
    private var breakdownToggleBand: ClosedRange<Double>? {
        guard let band = Self.breakdownLayout.toggleBand(
            rows: self.visibleBreakdownRows,
            hasToggle: self.hasBreakdownToggle
        ) else { return nil }
        let strip = Double(self.overflowStripHeight(
            rows: max(0, (self.detailDay?.byModel.count ?? 0) - Self.maxBreakdownRows)
        ))
        return (band.lowerBound + strip)...(band.upperBound + strip)
    }

    private var hasBreakdownToggle: Bool {
        guard let models = self.detailDay?.byModel.count else { return false }
        return models > Self.maxBreakdownRows || self.isBreakdownExpanded
    }

    /// The band the bars occupy, and the top of the breakdown under them, both measured from the
    /// top of the tracked block.
    private var chartBandHeight: CGFloat {
        self.bars.isEmpty ? 0 : Self.chartBottom + CostChartHoverMotion.markerBand
    }

    /// The baseline every bar stands on, which is where the pointer stops being on a bar. The mark
    /// under it is not a target: the reader points at bars.
    private static let chartBottom = Self.chartTopPadding + Self.chartHeight

    private var breakdownTop: CGFloat {
        self.bars.isEmpty ? 0 : self.chartBandHeight + Self.sectionSpacing
    }

    /// The overflow line doubles as the switch that opens the rest of the day. It cannot be a
    /// `Button` or an `.onTapGesture` -- an NSMenu popup is never the key window, so SwiftUI's
    /// gestures never fire inside the card -- so its click arrives through the same tracking view
    /// the chart reads, and its own height is pinned to what the hit test assumes.
    private func breakdownToggleRow(hiddenCount: Int) -> some View {
        HStack(spacing: 0) {
            // The chevron takes the column the rank bars are in, so the label starts on the same
            // left edge as the model names above it.
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                // A quarter turn spread over the reveal, so the glyph and the rows it stands for
                // are the same movement rather than two animations that happen to overlap.
                .rotationEffect(.degrees(90 * self.breakdownOpenness))
                .frame(width: Self.breakdownMarkerWidth, alignment: .leading)
            // Both labels are always there, so the wording crosses over on the same beat the rows
            // do instead of cutting under a list that is still moving.
            ZStack(alignment: .leading) {
                Text("+\(hiddenCount) more")
                    .opacity(1 - self.breakdownOpenness)
                Text("Show less")
                    .opacity(self.breakdownOpenness)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(self.isToggleHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .animation(.easeOut(duration: 0.12), value: self.isToggleHovered)
        .frame(height: CGFloat(Self.breakdownLayout.toggleHeight))
        .padding(.top, CGFloat(Self.breakdownLayout.spacing))
    }

    private func breakdownRow(
        source: CostUsageSource,
        model: String,
        isFast: Bool,
        usage: ModelDayUsage,
        index: Int
    ) -> some View {
        HStack(spacing: Self.breakdownMarkerGap) {
            // Each row fades a step further, so rank reads without numbering.
            Rectangle()
                .fill(Theme.accent(for: self.snapshot.provider).opacity(max(0.3, 0.75 - Double(index) * 0.12)))
                .frame(width: Self.breakdownBarWidth, height: 10)
            Text(self.breakdownLabel(source: source, model: model, isFast: isFast))
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Self.breakdownValue(usage))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: CGFloat(Self.breakdownLayout.rowHeight))
    }

    private func breakdownLabel(source: CostUsageSource, model: String, isFast: Bool) -> String {
        let base = self.snapshot.provider == .codex ? "\(source.displayName) · \(model)" : model
        return isFast ? "\(base) · Fast" : base
    }

    private static func breakdownValue(_ usage: ModelDayUsage) -> String {
        let tokens = Formatters.tokens(usage.tokens.total)
        guard let cost = usage.costUSD else { return "\(tokens) · no price" }
        return "\(tokens) · \(Formatters.cost(cost))"
    }

    /// Date, daily totals, and model details have separate visual levels. The 5pt lower inset
    /// joins the first model row's 7pt gap to leave 12pt beneath the separator.
    @ViewBuilder
    private var daySummary: some View {
        if let day = self.detailDay {
            VStack(alignment: .leading, spacing: 0) {
                Text(Formatters.dayLabel(day.dayKey))
                    .font(.system(size: 11, weight: .medium))
                    .frame(height: 14)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(Formatters.cost(day.costUSD ?? 0))
                        .font(.system(size: 17, weight: .medium))
                        .layoutPriority(1)
                    Text("\(Formatters.tokens(day.tokens.total)) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
                .frame(height: 21, alignment: .leading)
                .padding(.top, 7)
                Divider()
                    .frame(height: 1)
                    .padding(.top, 12)
            }
            .padding(.bottom, 5)
        } else {
            Text("\(self.bars.count) days with activity · hover a bar for a day")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func updateHover(at location: CGPoint?, width: CGFloat) {
        // The tracking area covers the chart and breakdown, but only a bar and its label own
        // chart hover.
        guard let location, width > 0 else {
            if self.hoveredDayKey != nil { self.select(nil) }
            let nextDetailKey = CostChartHighlightPolicy.detailDayKey(
                afterMovingTo: nil,
                currentDayKey: self.detailDayKey,
                availableDayKeys: self.barDayKeys,
                defaultDayKey: self.bars.last?.dayKey
            )
            if self.detailDayKey != nextDetailKey { self.detailDayKey = nextDetailKey }
            if self.isToggleHovered { self.isToggleHovered = false }
            return
        }
        let region = self.region(at: location, width: width)
        if self.isToggleHovered != (region == .breakdownToggle) {
            self.isToggleHovered = region == .breakdownToggle
        }
        guard !self.bars.isEmpty else { return }
        // Every pointer move replaces the hover with the bar or label under the pointer. A gap or
        // a point below the chart has no day key, so it clears the hover.
        let key = self.dayKey(for: region)
        let nextDetailKey = CostChartHighlightPolicy.detailDayKey(
            afterMovingTo: key,
            currentDayKey: self.detailDayKey,
            availableDayKeys: self.barDayKeys,
            defaultDayKey: self.bars.last?.dayKey
        )
        if self.hoveredDayKey != key { self.select(key) }
        if self.detailDayKey != nextDetailKey { self.detailDayKey = nextDetailKey }
    }

    private func region(at location: CGPoint, width: CGFloat) -> CostChartHighlightPolicy.Region {
        let maxValue = self.maxValue
        let selectedDayKey = self.selectedDayKey
        let barHeights = self.bars.map { day in
            let value = CostChartHighlightPolicy.value(for: day, mode: self.selectedLabelMode)
            let ratio = maxValue > 0 ? value / maxValue : 0
            return Double(self.barHeight(valueRatio: ratio))
        }
        let labelSizes = self.bars.map { day in
            day.dayKey == selectedDayKey ? self.labelSize(for: day) : nil
        }
        return CostChartHighlightPolicy.region(
            at: location,
            width: width,
            chartBottom: self.bars.isEmpty ? 0 : Self.chartBottom,
            barHeights: barHeights,
            labelSizes: labelSizes,
            labelOffsetY: Self.labelOffsetY,
            spacing: Self.barSpacing,
            detailTop: self.breakdownTop,
            toggleBand: self.breakdownToggleBand
        )
    }

    private func dayKey(for region: CostChartHighlightPolicy.Region) -> String? {
        switch region {
        case let .bar(index), let .label(index):
            return self.bars[index].dayKey
        case .breakdownToggle, .elsewhere:
            return nil
        }
    }

    /// Clearing the hover is the one move the reader did not aim at a bar, so it gets the slower
    /// clear curve.
    private func select(_ dayKey: String?) {
        let animation = CostChartHoverMotion.animation(
            clearingHover: dayKey == nil,
            reduceMotion: CostChartHoverMotion.systemReduceMotion
        )
        withAnimation(animation) { self.hoveredDayKey = dayKey }
    }

    private var selectedDayKey: String? {
        CostChartHighlightPolicy.selectedDayKey(
            hoveredDayKey: self.hoveredDayKey,
            availableDayKeys: self.barDayKeys
        )
    }

#if DEBUG
    var debugSelectedDayKey: String? { self.selectedDayKey }
#endif

    private func handleClick(at location: CGPoint, width: CGFloat) {
        switch self.region(at: location, width: width) {
        case let .bar(index), let .label(index):
            self.toggleLabel(dayKey: self.bars[index].dayKey)
        case .breakdownToggle:
            self.onBreakdownExpandedChanged(!self.isBreakdownExpanded, self.detailDay?.dayKey)
        case .elsewhere:
            break
        }
    }

    private func toggleLabel(dayKey clickedDayKey: String) {
        let nextMode = CostChartHighlightPolicy.labelMode(
            afterClicking: clickedDayKey,
            selectedDayKey: self.selectedDayKey,
            currentMode: self.selectedLabelMode
        )
        guard nextMode != self.selectedLabelMode else { return }
        // The unit change is the one thing on this chart the reader asks for by clicking, so it
        // is drawn rather than assigned: the old reading blurs out and the new one resolves.
        let animation = CostChartHoverMotion.swapAnimation(
            reduceMotion: CostChartHoverMotion.systemReduceMotion
        )
        withAnimation(animation) { self.selectedLabelMode = nextMode }
        self.onLabelModeChanged(nextMode)
    }


    // MARK: - Disclaimer

    /// Both providers are priced the same way — local logs, published API rates, cache tokens
    /// included — so the wording stays identical rather than drifting per provider.
    private var disclaimer: String {
        var text = "Local-log estimate at API rates, not a bill · cache tokens included"
        if self.snapshot.hasUnpricedTokens {
            text += " · unpriced models excluded"
        }
        return text
    }
}

/// Codex's pay-as-you-go credit balance. Claude does not report one.
struct CreditsSectionView: View {
    let credits: CreditsSnapshot

    /// CodexBar scales the credit bar against a 1000-token cap.
    private static let cap: Double = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credits")
                .font(.system(size: 13, weight: .semibold))
            UsageProgressBar(
                percent: self.credits.unlimited ? 100 : min(100, (self.credits.balance ?? 0) / Self.cap * 100),
                tint: Theme.accent(for: .codex)
            )
            HStack {
                Text(self.leftLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("1K tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var leftLabel: String {
        if self.credits.unlimited { return "Unlimited" }
        return "\(Int((self.credits.balance ?? 0).rounded())) left"
    }
}
