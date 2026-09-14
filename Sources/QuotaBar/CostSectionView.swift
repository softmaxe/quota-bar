import AppKit
import QuotaBarCore
import SwiftUI

/// Local usage from the last completed scan. Each chart button owns a full calendar-day column.
struct CostSectionView: View {
    let snapshot: CostSnapshot

    private static let maxBars = 10
    private static let chartHeight: CGFloat = 56
    private static let chartLabelHeight: CGFloat = 17
    static let breakdownLayout = CostBreakdownLayout(
        summaryHeight: 61,
        rowHeight: 17,
        toggleHeight: 22,
        spacing: 5
    )

    @State private var selectedLabelMode: CostChartLabelMode
    @State private var hoveredDayKey: String?
    @State private var detailDayKey: String?
    @State private var pinnedDayKey: String?
    @FocusState private var focusedDayKey: String?

    private let todayDayKey: String
    private let bars: [CostDay]
    private let barDayKeys: Set<String>
    private let unobservedDayKeys: Set<String>
    private let onLabelModeChanged: (CostChartLabelMode) -> Void
    private let onOpenPricing: (() -> Void)?
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
        breakdownOpenness: Double? = nil,
        expandedBreakdownDayKey: String? = nil,
        previewToggleHovered: Bool = false,
        onBreakdownExpandedChanged: @escaping (Bool, String?) -> Void = { _, _ in },
        onOpenPricing: (() -> Void)? = nil
    ) {
        let todayKey = previewTodayDayKey ?? Formatters.dayKey(for: Date())
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
        self._detailDayKey = State(initialValue: previewHoveredDayKey ?? bars.last?.dayKey)
        self.onLabelModeChanged = onLabelModeChanged
        self.onOpenPricing = onOpenPricing
        self.isBreakdownExpanded = isBreakdownExpanded
        self.breakdownOpenness = breakdownOpenness ?? (isBreakdownExpanded ? 1 : 0)
        self.expandedBreakdownDayKey = expandedBreakdownDayKey
        self.onBreakdownExpandedChanged = onBreakdownExpandedChanged
        _ = previewToggleHovered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Picker("Usage unit", selection: Binding(
                    get: { self.selectedLabelMode },
                    set: { self.changeMode(to: $0) }
                )) {
                    Text("Tokens").tag(CostChartLabelMode.tokens)
                    Text("Cost").tag(CostChartLabelMode.cost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .accessibilityLabel("Usage unit")
            }

            self.kpiGrid
            self.chart
            self.dayDetail
            self.modelDisclosure
            self.estimateNote
        }
        .onChange(of: self.snapshot) { previous, current in
            self.reconcileSelection(providerChanged: previous.provider != current.provider)
        }
        .onChange(of: self.todayDayKey) { _, _ in
            self.reconcileSelection(providerChanged: false)
        }
        .onChange(of: self.parentLabelMode) { _, newMode in
            if self.selectedLabelMode != newMode { self.selectedLabelMode = newMode }
        }
    }

    /// The parent supplies the saved preference; the Picker updates that same preference.
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
        withAnimation(CostChartHoverMotion.swapAnimation(
            reduceMotion: CostChartHoverMotion.systemReduceMotion
        )) {
            self.selectedLabelMode = mode
        }
        self.onLabelModeChanged(mode)
    }

    private var kpiGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16) {
            GridRow {
                self.kpi(
                    label: "Today",
                    value: self.isUnobserved(self.todayDayKey) ? "—" : self.selectedLabelMode == .tokens
                        ? Formatters.tokens(self.todayDay.tokens.total)
                        : self.costValue(self.todayDay.costAvailability),
                    status: self.isUnobserved(self.todayDayKey) ? "Not scanned yet" : self.selectedLabelMode == .cost
                        ? self.status(self.todayDay.costAvailability) : nil
                )
                self.kpi(
                    label: "Last 30 days",
                    value: self.selectedLabelMode == .tokens
                        ? Formatters.tokens(self.snapshot.windowTokens)
                        : self.costValue(self.snapshot.windowCostAvailability),
                    status: self.selectedLabelMode == .cost
                        ? self.status(self.snapshot.windowCostAvailability) : nil
                )
            }
        }
    }

    private func kpi(label: String, value: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            if let status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 10 calendar days")
                Spacer(minLength: 4)
                Text(self.selectedLabelMode == .tokens ? "Tokens" : "Cost")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let slotWidth = geometry.size.width / CGFloat(max(1, self.bars.count))
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(self.bars, id: \.dayKey) { day in
                            self.dayButton(day)
                                .frame(width: slotWidth)
                        }
                    }
                    if let day = self.selectedDay,
                       let index = self.bars.firstIndex(where: { $0.dayKey == day.dayKey }) {
                        let label = self.chartLabel(for: day)
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .fixedSize()
                            .position(
                                x: self.labelCenter(
                                    for: label,
                                    index: index,
                                    slotWidth: slotWidth,
                                    chartWidth: geometry.size.width
                                ),
                                y: Self.chartLabelHeight / 2
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: Self.chartLabelHeight + Self.chartHeight + CostChartHoverMotion.markerBand)
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
            self.selectDay(day.dayKey)
        } label: {
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.chartLabelHeight)
                ZStack(alignment: .bottom) {
                    Color.clear
                    if value > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent(for: self.snapshot.provider))
                            .opacity(CostChartHighlightPolicy.opacity(
                                dayKey: day.dayKey,
                                selectedDayKey: self.selectedDayKey
                            ))
                            .frame(height: max(2, height))
                            .padding(.horizontal, 2)
                    } else {
                        Text(self.zeroMark(for: day))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(height: 11, alignment: .bottom)
                    }
                }
                .frame(height: Self.chartHeight)
                Capsule()
                    .fill(Theme.accent(for: self.snapshot.provider))
                    .frame(width: 12, height: CostChartHoverMotion.markerHeight)
                    .opacity(selected ? 1 : 0)
                    .frame(height: CostChartHoverMotion.markerBand)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            guard self.pinnedDayKey == nil, !self.isBreakdownExpanded else { return }
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
        .help("\(self.fullDate(day.dayKey)): \(self.accessibleDayValue(day))")
    }

    private func chartLabel(for day: CostDay) -> String {
        if self.isUnobserved(day.dayKey) { return "—" }
        return switch self.selectedLabelMode {
        case .tokens: Formatters.tokens(day.tokens.total)
        case .cost: day.costAvailability.knownUSD.map(Formatters.compactCost) ?? "—"
        }
    }

    private func zeroMark(for day: CostDay) -> String {
        if self.isUnobserved(day.dayKey) { return "—" }
        if self.selectedLabelMode == .cost, day.costAvailability.state == .unpriced {
            return "—"
        }
        return "0"
    }

    private func labelCenter(
        for label: String,
        index: Int,
        slotWidth: CGFloat,
        chartWidth: CGFloat
    ) -> CGFloat {
        let width = (label as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ]).width
        let half = min(chartWidth / 2, width / 2 + 2)
        let natural = (CGFloat(index) + 0.5) * slotWidth
        return min(chartWidth - half, max(half, natural))
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
            hoveredDayKey: self.isBreakdownExpanded ? nil : self.hoveredDayKey,
            detailDayKey: self.validExpandedDayKey ?? self.detailDayKey,
            availableDayKeys: self.barDayKeys,
            defaultDayKey: self.bars.last?.dayKey
        )
    }

    private var validExpandedDayKey: String? {
        guard self.isBreakdownExpanded, let key = self.expandedBreakdownDayKey,
              self.barDayKeys.contains(key) else { return nil }
        return key
    }

    private var todayDay: CostDay {
        self.bars.last(where: { $0.dayKey == self.todayDayKey }) ?? CostDay(
            dayKey: self.todayDayKey, byModel: [:], costUSD: 0, unpricedTokens: 0
        )
    }

    private var selectedDay: CostDay? {
        self.bars.first { $0.dayKey == self.selectedDayKey }
    }

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(self.selectedDay.map { Formatters.dayLabel($0.dayKey) } ?? "Day")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let day = self.selectedDay, !day.byModel.isEmpty {
                    Text("\(day.byModel.count) models")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let day = self.selectedDay {
                if self.isUnobserved(day.dayKey) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("—")
                            .font(.system(size: 17, weight: .medium))
                        Text("Not scanned yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        let cost = self.costValue(day.costAvailability)
                        let tokens = "\(Formatters.tokens(day.tokens.total)) tokens"
                        Text(self.selectedLabelMode == .tokens ? tokens : cost)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(self.selectedLabelMode == .tokens ? cost : tokens)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .monospacedDigit()
                    if let status = self.status(day.costAvailability) {
                        Text(self.availabilityDetail(status, day.costAvailability))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
        }
    }

    private var modelDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                self.onBreakdownExpandedChanged(!self.isBreakdownExpanded, self.selectedDayKey)
            } label: {
                HStack {
                    Text("Model breakdown")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(self.breakdownOpenness * 90))
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
                .frame(height: CGFloat(Self.breakdownLayout.toggleHeight))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model breakdown")
            .accessibilityValue(self.isBreakdownExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(self.isBreakdownExpanded ? "Collapse model list" : "Expand model list")

            let ranked = self.selectedDay?.rankedModels(by: self.selectedLabelMode) ?? []
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ranked.enumerated()), id: \.element.key) { index, entry in
                    self.breakdownRow(entry, index: index)
                        .frame(height: CGFloat(Self.breakdownLayout.rowHeight), alignment: .leading)
                        .padding(.top, CGFloat(Self.breakdownLayout.spacing))
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

    private func breakdownRow(
        _ entry: (key: ModelUsageKey, model: String, usage: ModelDayUsage),
        index: Int
    ) -> some View {
        let name = self.breakdownLabel(entry.key)
        let amount = entry.usage.costUSD.map(Formatters.cost) ?? "No price"
        return HStack(spacing: 6) {
            Rectangle()
                .fill(Theme.accent(for: self.snapshot.provider).opacity(max(0.3, 0.75 - Double(index) * 0.08)))
                .frame(width: 2, height: 10)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(Formatters.tokens(entry.usage.tokens.total)) · \(amount)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(entry.usage.tokens.total) tokens, \(amount)")
    }

    private func breakdownLabel(_ key: ModelUsageKey) -> String {
        let base = "\(key.source.displayName) · \(key.model)"
        return key.isFast ? "\(base) · Fast" : base
    }

    private var estimateNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("API-rate estimate · Not a bill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if self.snapshot.windowCostAvailability.unpricedTokens > 0,
                   let onOpenPricing = self.onOpenPricing {
                    Button("Pricing", action: onOpenPricing)
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .accessibilityHint("Open model rates for unpriced usage")
                }
            }
            if let status = self.status(self.snapshot.windowCostAvailability) {
                Text(self.availabilityDetail(status, self.snapshot.windowCostAvailability))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
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

    private func availabilityDetail(_ status: String, _ availability: CostAvailability) -> String {
        "\(status) · \(Formatters.tokens(availability.unpricedTokens)) tokens have no price"
    }

#if DEBUG
    var debugSelectedDayKey: String? { self.pinnedDayKey ?? self.hoveredDayKey }
#endif
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
