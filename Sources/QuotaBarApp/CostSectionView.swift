import QuotaBarCore
import SwiftUI

/// Local usage from the last completed scan. Each chart button owns a full calendar-day column.
struct CostSectionView: View {
    let snapshot: CostSnapshot

    private static let maxBars = 10
    private static let chartHeight: CGFloat = 56
    /// A day with no value keeps a low neutral stub on the baseline so the row stays continuous.
    /// Nonzero bars start one point taller and in the accent, so small usage never reads as none.
    private static let emptyStubHeight: CGFloat = 3
    private static let minimumBarHeight: CGFloat = 4
    /// How far the day summary's hover highlight reaches past its text.
    private static let summaryInset: CGFloat = 6
    /// A row is a line of text over its share bar.
    static let breakdownLayout = CostBreakdownLayout(
        rowHeight: 21,
        spacing: 7
    )

    @State private var selectedLabelMode: CostChartLabelMode
    @State private var hoveredDayKey: String?
    @State private var detailDayKey: String?
    @State private var pinnedDayKey: String?
    @State private var summaryHovered = false
    @FocusState private var focusedDayKey: String?

    private let todayDayKey: String
    private let bars: [CostDay]
    private let barDayKeys: Set<String>
    private let unobservedDayKeys: Set<String>
    private let onLabelModeChanged: (CostChartLabelMode) -> Void
    private let isBreakdownExpanded: Bool
    private let breakdownOpenness: Double
    private let expandedBreakdownDayKey: String?
    private let onBreakdownExpandedChanged: (Bool, String?) -> Void

    init(
        snapshot: CostSnapshot,
        previewHoveredDayKey: String? = nil,
        previewTodayDayKey: String? = nil,
        labelMode: CostChartLabelMode = .tokens,
        onLabelModeChanged: @escaping (CostChartLabelMode) -> Void = { _ in },
        isBreakdownExpanded: Bool = false,
        expandedBreakdownDayKey: String? = nil,
        onBreakdownExpandedChanged: @escaping (Bool, String?) -> Void = { _, _ in }
    ) {
        let todayKey = previewTodayDayKey ?? DayKey.make(from: Date())
        let bars = CostChartHighlightPolicy.visibleDays(
            from: snapshot.days,
            todayDayKey: todayKey,
            maxBars: Self.maxBars
        )
        self.snapshot = snapshot
        self.todayDayKey = todayKey
        self.bars = bars
        self.barDayKeys = Set(bars.map(\.dayKey))
        self.unobservedDayKeys = CostChartHighlightPolicy.unobservedDayKeys(
            visibleDays: bars,
            recordedDays: snapshot.days,
            scannedAt: snapshot.scannedAt
        )
        self._selectedLabelMode = State(initialValue: labelMode)
        self.parentLabelMode = labelMode
        self._hoveredDayKey = State(initialValue: previewHoveredDayKey)
        // An open model list keeps describing its day when the card is rebuilt.
        let expandedDayKey = isBreakdownExpanded
            ? expandedBreakdownDayKey.flatMap { key in bars.contains { $0.dayKey == key } ? key : nil }
            : nil
        self._detailDayKey = State(initialValue: previewHoveredDayKey ?? expandedDayKey ?? bars.last?.dayKey)
        self.onLabelModeChanged = onLabelModeChanged
        self.isBreakdownExpanded = isBreakdownExpanded
        self.breakdownOpenness = isBreakdownExpanded ? 1 : 0
        self.expandedBreakdownDayKey = expandedBreakdownDayKey
        self.onBreakdownExpandedChanged = onBreakdownExpandedChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                UsageUnitSwitch(selection: self.selectedLabelMode) { self.changeMode(to: $0) }
                    .frame(width: 130)
                    .accessibilityLabel("Usage unit")
            }

            self.kpiRow
            self.chart
            self.dayDetail
        }
        .onChange(of: self.snapshot) { previous, current in
            self.reconcileSelection(providerChanged: previous.provider != current.provider)
        }
        .onChange(of: self.todayDayKey) { _, _ in
            self.reconcileSelection(providerChanged: false)
        }
        .onChange(of: self.parentLabelMode) { _, newMode in
            guard self.selectedLabelMode != newMode else { return }
            withTransaction(Transaction(animation: nil)) {
                self.selectedLabelMode = newMode
            }
        }
    }

    /// The parent supplies the saved preference; the switch updates that same preference.
    private let parentLabelMode: CostChartLabelMode

    private func reconcileSelection(providerChanged: Bool) {
        if providerChanged {
            self.pinnedDayKey = nil
            self.hoveredDayKey = nil
            self.detailDayKey = self.bars.last?.dayKey
            self.focusedDayKey = nil
            if self.isBreakdownExpanded {
                self.onBreakdownExpandedChanged(false, nil)
            }
            return
        }
        if let key = self.pinnedDayKey, !self.barDayKeys.contains(key) {
            self.pinnedDayKey = nil
        }
        if let key = self.hoveredDayKey, !self.barDayKeys.contains(key) {
            self.hoveredDayKey = nil
        }
        if let key = self.focusedDayKey, !self.barDayKeys.contains(key) {
            self.focusedDayKey = nil
        }
        if let key = self.detailDayKey, !self.barDayKeys.contains(key) {
            self.detailDayKey = self.pinnedDayKey ?? self.bars.last?.dayKey
        }
        if self.isBreakdownExpanded,
           let key = self.expandedBreakdownDayKey,
           !self.barDayKeys.contains(key) {
            self.onBreakdownExpandedChanged(false, nil)
        }
    }

    private func changeMode(to mode: CostChartLabelMode) {
        guard mode != self.selectedLabelMode else { return }
        // Only the switch's pill animates. Keep the change out of the card layout.
        withTransaction(Transaction(animation: nil)) {
            self.selectedLabelMode = mode
            self.onLabelModeChanged(mode)
        }
    }

    /// The left figure reads out the selected day, as a stock chart's header follows the pointer;
    /// it says Today until another day is hovered or pinned.
    private var kpiRow: some View {
        let day = self.shownDay
        let unobserved = self.isUnobserved(day.dayKey)
        let dayTokens = Formatters.tokens(day.tokens.total)
        let dayCost = self.costValue(day.costAvailability)
        let windowTokens = Formatters.tokens(self.snapshot.windowTokens)
        let windowCost = self.costValue(self.snapshot.windowCostAvailability)
        let showsTokens = self.selectedLabelMode == .tokens
        return HStack(alignment: .top, spacing: 16) {
            self.kpi(
                label: day.dayKey == self.todayDayKey ? "Today" : Formatters.dayLabel(day.dayKey),
                value: unobserved ? "—" : showsTokens ? dayTokens : dayCost,
                detail: unobserved ? "Not scanned yet" : showsTokens ? dayCost : "\(dayTokens) tokens"
            )
            self.kpi(
                label: "Last 30 days",
                value: showsTokens ? windowTokens : windowCost,
                detail: showsTokens ? windowCost : "\(windowTokens) tokens"
            )
        }
    }

    private func kpi(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            // Keyed to the data rather than the text: a rescan rolls the value, a unit change or
            // another day swaps it.
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .rollingValue(self.snapshot)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let slotWidth = geometry.size.width / CGFloat(max(1, self.bars.count))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(self.bars, id: \.dayKey) { day in
                        self.dayButton(day)
                            .frame(width: slotWidth)
                    }
                }
            }
            .frame(height: Self.chartHeight + CostChartHoverMotion.markerBand)
            .onMoveCommand { direction in
                switch direction {
                case .left: self.moveSelection(by: -1)
                case .right: self.moveSelection(by: 1)
                default: break
                }
            }

            HStack {
                Text(self.bars.first.map { self.rangeLabel($0.dayKey) } ?? "")
                Spacer(minLength: 4)
                Text(self.bars.last.map { self.rangeLabel($0.dayKey) } ?? "")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func dayButton(_ day: CostDay) -> some View {
        let selected = day.dayKey == self.selectedDayKey
        let value = CostChartHighlightPolicy.value(for: day, mode: self.selectedLabelMode)
        let maxValue = CostChartHighlightPolicy.maxValue(for: self.bars, mode: self.selectedLabelMode)
        let height = maxValue > 0 ? Self.chartHeight * CGFloat(value / maxValue) : 0

        return Button {
            self.toggleDay(day.dayKey)
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    if value > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent(for: self.snapshot.provider))
                            .opacity(CostChartHighlightPolicy.opacity(
                                dayKey: day.dayKey,
                                selectedDayKey: self.selectedDayKey
                            ))
                            .animation(CostChartHoverMotion.selection, value: selected)
                            .frame(height: max(Self.minimumBarHeight, height))
                            .padding(.horizontal, 2)
                    } else {
                        self.emptyStub(for: day)
                            .opacity(CostChartHighlightPolicy.opacity(
                                dayKey: day.dayKey,
                                selectedDayKey: self.selectedDayKey
                            ))
                            .animation(CostChartHoverMotion.selection, value: selected)
                            .frame(height: Self.emptyStubHeight)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(height: Self.chartHeight)
                Capsule()
                    .fill(Theme.accent(for: self.snapshot.provider))
                    .frame(width: 12, height: CostChartHoverMotion.markerHeight)
                    .opacity(selected ? 1 : 0)
                    .animation(CostChartHoverMotion.selection, value: selected)
                    .frame(height: CostChartHoverMotion.markerBand)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        // Bars carry a quantity, so a press dims them without changing their drawn height.
        .buttonStyle(ControlFeedbackStyle(pressScale: 1))
        .frame(maxWidth: .infinity)
        .focused(self.$focusedDayKey, equals: day.dayKey)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    Theme.accent(for: self.snapshot.provider),
                    lineWidth: self.focusedDayKey == day.dayKey ? 1.5 : 0
                )
                .padding(.horizontal, 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { hovering in
            guard self.pinnedDayKey == nil else { return }
            if hovering {
                self.hoveredDayKey = day.dayKey
                self.detailDayKey = day.dayKey
            } else if self.hoveredDayKey == day.dayKey {
                self.hoveredDayKey = nil
            }
        }
        .accessibilityLabel(self.fullDate(day.dayKey))
        .accessibilityValue(self.accessibleDayValue(day))
        .accessibilityHint("Select day. Use Left and Right Arrow to change day.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A known zero is a solid stub; a day whose value is unknown is only outlined.
    @ViewBuilder
    private func emptyStub(for day: CostDay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 1.5)
        if self.isUnknownValue(day) {
            shape.strokeBorder(
                Theme.chartEmptyStub,
                style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])
            )
        } else {
            shape.fill(Theme.chartEmptyStub)
        }
    }

    private func isUnknownValue(_ day: CostDay) -> Bool {
        self.isUnobserved(day.dayKey)
            || (self.selectedLabelMode == .cost && day.costAvailability.state == .unpriced)
    }

    private func accessibleDayValue(_ day: CostDay) -> String {
        if self.isUnobserved(day.dayKey) { return "Not scanned yet" }
        let availability = day.costAvailability
        let tokens = "\(day.tokens.total) tokens"
        let cost = self.costValue(availability)
        let pricing = self.status(availability)
        let mode = self.selectedLabelMode == .tokens ? "Tokens selected" : "Cost selected"
        return [mode, tokens, cost, pricing].compactMap { $0 }.joined(separator: ", ")
    }

    private func fullDate(_ key: String) -> String {
        "\(Formatters.dayLabel(key)), \(key.prefix(4))"
    }

    private func isUnobserved(_ dayKey: String) -> Bool {
        self.unobservedDayKeys.contains(dayKey)
    }

    private func rangeLabel(_ key: String) -> String {
        guard let first = self.bars.first, let last = self.bars.last,
              first.dayKey.prefix(4) != last.dayKey.prefix(4) else {
            return Formatters.dayLabel(key)
        }
        return self.fullDate(key)
    }

    private func selectDay(_ key: String) {
        self.pinnedDayKey = key
        self.detailDayKey = key
        self.hoveredDayKey = nil
        self.focusedDayKey = key
        if self.isBreakdownExpanded {
            self.onBreakdownExpandedChanged(true, key)
        }
    }

    /// A second click on the pinned day releases it so hovering drives the chart, and an open
    /// model list, again.
    private func toggleDay(_ key: String) {
        guard self.pinnedDayKey == key else {
            self.selectDay(key)
            return
        }
        self.pinnedDayKey = nil
        // The pointer still rests on this bar, and no new hover event fires until it moves.
        self.hoveredDayKey = key
        self.detailDayKey = key
    }

    private func moveSelection(by direction: Int) {
        guard let next = CostChartHighlightPolicy.nextDayKey(
            from: self.selectedDayKey,
            direction: direction,
            days: self.bars
        ) else { return }
        self.selectDay(next)
    }

    private var selectedDayKey: String? {
        CostChartHighlightPolicy.selectedDayKey(
            pinnedDayKey: self.pinnedDayKey,
            hoveredDayKey: self.hoveredDayKey,
            detailDayKey: self.detailDayKey,
            availableDayKeys: self.barDayKeys,
            defaultDayKey: self.bars.last?.dayKey
        )
    }

    private var todayDay: CostDay {
        self.bars.last(where: { $0.dayKey == self.todayDayKey }) ?? CostDay(
            dayKey: self.todayDayKey, byModel: [:], costUSD: 0, unpricedTokens: 0
        )
    }

    private var selectedDay: CostDay? {
        self.bars.first { $0.dayKey == self.selectedDayKey }
    }

    /// The day the figures and the model list describe: the selected one, or today before any
    /// day has data.
    private var shownDay: CostDay {
        self.selectedDay ?? self.todayDay
    }

    /// A single row under the chart opens the shown day's model list; its totals are already in
    /// the figures above.
    @ViewBuilder
    private var dayDetail: some View {
        let ranked = self.selectedDay?.rankedModels(by: self.selectedLabelMode) ?? []
        let dayTotal = ranked.reduce(0) { $0 + self.breakdownValue($1.usage) }
        // A day with no models has nothing to open, unless the list is already open and has to
        // close again.
        let canToggle = !ranked.isEmpty || self.isBreakdownExpanded
        VStack(alignment: .leading, spacing: 0) {
            if canToggle {
                Button {
                    self.onBreakdownExpandedChanged(!self.isBreakdownExpanded, self.selectedDayKey)
                } label: {
                    self.dayToggleLabel(models: ranked.count, showsChevron: true)
                        .padding(.horizontal, Self.summaryInset)
                        .padding(.vertical, Self.summaryInset / 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
                .background(
                    self.summaryHovered ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .animation(
                    CostChartHoverMotion.systemReduceMotion ? nil : .easeOut(duration: 0.10),
                    value: self.summaryHovered
                )
                // The highlight reaches past the text; the text stays aligned with the card.
                .padding(.horizontal, -Self.summaryInset)
                .padding(.vertical, -Self.summaryInset / 2)
                .onHover { self.summaryHovered = $0 }
                .accessibilityValue(self.isBreakdownExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(self.isBreakdownExpanded ? "Collapse model list" : "Expand model list")
            } else {
                self.dayToggleLabel(models: ranked.count, showsChevron: false)
            }

            self.cacheMix
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                if self.isBreakdownExpanded {
                    // The height cuts open; the rows rise into place together, like every other
                    // disclosure in the card.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(ranked, id: \.key) { entry in
                            self.breakdownRow(
                                entry,
                                share: dayTotal > 0 ? self.breakdownValue(entry.usage) / dayTotal : 0
                            )
                                .frame(height: CGFloat(Self.breakdownLayout.rowHeight), alignment: .leading)
                                .padding(.top, CGFloat(Self.breakdownLayout.spacing))
                        }
                    }
                    .cardReveal()
                    .transition(.identity)
                }
            }
            .frame(height: CGFloat(Self.breakdownLayout.rowsHeight(
                rows: ranked.count,
                openness: self.breakdownOpenness
            )), alignment: .top)
            .clipped()
            .opacity(self.breakdownOpenness)
            .accessibilityHidden(self.breakdownOpenness < 1)
        }
    }

    private func dayToggleLabel(models: Int, showsChevron: Bool) -> some View {
        let day = self.shownDay
        let count = switch models {
        case 0: self.isUnobserved(day.dayKey) ? "Not scanned yet" : "No usage"
        case 1: "1 model"
        default: "\(models) models"
        }
        return HStack(spacing: 6) {
            Text(Formatters.dayLabel(day.dayKey))
                .fontWeight(.medium)
            Text(count)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(self.breakdownOpenness * 90))
                    .animation(DisclosureMotion.open(
                        reduceMotion: CostChartHoverMotion.systemReduceMotion
                    ), value: self.breakdownOpenness)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shown day's cache hit rate over a bar of how its tokens split between cache reads,
    /// cache writes, fresh input, and output. It keeps its height on a day with no usage, so the
    /// card does not jump as the pointer crosses the chart.
    private var cacheMix: some View {
        let day = self.shownDay
        let tokens = self.isUnobserved(day.dayKey) ? TokenTotals() : day.tokens
        let accent = Theme.accent(for: self.snapshot.provider)
        let parts: [(label: String, count: Int, color: Color)] = [
            ("Cache read", tokens.cacheRead, accent),
            ("Cache write", tokens.cacheWrite, accent.opacity(0.45)),
            ("Input", tokens.input, Color.primary.opacity(0.5)),
            ("Output", tokens.output, Color.primary.opacity(0.25)),
        ]
        let inputTokens = tokens.input + tokens.cacheWrite + tokens.cacheRead
        let rate = tokens.cacheHitRate.map(Self.hitRateLabel) ?? "—"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Cache hit").foregroundStyle(.secondary)
                Text(rate).fontWeight(.medium)
                Spacer(minLength: 4)
                if inputTokens > 0 {
                    Text("\(Formatters.tokens(tokens.cacheRead)) of \(Formatters.tokens(inputTokens)) input")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)

            GeometryReader { geometry in
                let shown = parts.filter { $0.count > 0 }
                let gaps = CGFloat(max(0, shown.count - 1))
                let width = max(0, geometry.size.width - gaps)
                HStack(spacing: 1) {
                    ForEach(shown, id: \.label) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, width * CGFloat(part.count) / CGFloat(tokens.total)))
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .background(Theme.progressTrack)
                .clipShape(Capsule())
                .animation(CostChartHoverMotion.selection, value: day.dayKey)
            }
            .frame(height: 4)

            HStack(spacing: 8) {
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(part.color)
                            .frame(width: 6, height: 6)
                        Text(part.label)
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help(parts.map { "\($0.label) \(Formatters.tokens($0.count))" }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cache hit rate")
        .accessibilityValue(
            ([rate] + parts.map { "\($0.label) \($0.count) tokens" }).joined(separator: ", ")
        )
    }

    /// Whole percents, but never a round 100% while some input missed the cache, or 0% while
    /// some of it hit.
    private static func hitRateLabel(_ rate: Double) -> String {
        let percent = Int((rate * 100).rounded())
        if percent == 100, rate < 1 { return "99%" }
        if percent == 0, rate > 0 { return "<1%" }
        return "\(percent)%"
    }

    /// The tool's mark and the model's name over a bar of its share of the day, in the chosen unit.
    private func breakdownRow(
        _ entry: (key: ModelUsageKey, model: String, usage: ModelDayUsage),
        share: Double
    ) -> some View {
        let name = Formatters.modelName(entry.model)
        let amount = entry.usage.costUSD.map(Formatters.cost) ?? "No price"
        let tokens = Formatters.tokens(entry.usage.tokens.total)
        let showsCost = self.selectedLabelMode == .cost
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SourceMark(source: entry.key.source, size: 12)
                Text(name)
                    .truncationMode(.middle)
                if entry.key.isFast {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(showsCost ? amount : tokens)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showsCost && entry.usage.costUSD == nil ? .secondary : .primary)
                    .layoutPriority(1)
                Text(showsCost ? tokens : amount)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 34, alignment: .trailing)
                    .layoutPriority(1)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.progressTrack)
                    if share > 0 {
                        Capsule()
                            .fill(Theme.accent(for: self.snapshot.provider))
                            .frame(width: max(3, geometry.size.width * share))
                    }
                }
            }
            .frame(height: 3)
            // Under the name, clear of the mark.
            .padding(.leading, 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.breakdownLabel(entry.key, name: name))
        .accessibilityValue("\(entry.usage.tokens.total) tokens, \(amount), \(Int((share * 100).rounded()))% of the day")
    }

    private func breakdownValue(_ usage: ModelDayUsage) -> Double {
        self.selectedLabelMode == .tokens ? Double(usage.tokens.total) : usage.costUSD ?? 0
    }

    private func breakdownLabel(_ key: ModelUsageKey, name: String) -> String {
        let base = "\(key.source.displayName), \(name)"
        return key.isFast ? "\(base), Fast" : base
    }

    private func costValue(_ availability: CostAvailability) -> String {
        availability.knownUSD.map(Formatters.cost) ?? "—"
    }

    private func status(_ availability: CostAvailability) -> String? {
        switch availability.state {
        case .priced: nil
        case .partial: "Partial estimate"
        case .unpriced: "Unpriced"
        }
    }
}

/// Codex's pay-as-you-go credit balance. Claude does not report one.
struct CreditsSectionView: View {
    let credits: CreditsSnapshot
    private static let cap: Double = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credits").font(.system(size: 13, weight: .semibold))
            UsageProgressBar(
                percent: self.credits.unlimited ? 100 : min(100, (self.credits.balance ?? 0) / Self.cap * 100),
                tint: Theme.accent(for: .codex)
            )
            HStack {
                Text(self.leftLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("1K tokens").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var leftLabel: String {
        if self.credits.unlimited { return "Unlimited" }
        return "\(Int((self.credits.balance ?? 0).rounded())) left"
    }
}
