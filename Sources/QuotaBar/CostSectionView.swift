import QuotaBarCore
import SwiftUI

/// Local usage from every provider's last completed scan, read as one. Each chart button owns a
/// full calendar-day column, stacked by provider in the card's order.
struct CostSectionView: View {
    /// One per provider with a scan, in `Provider.allCases` order.
    let snapshots: [CostSnapshot]

    private static let maxBars = 10
    private static let chartHeight: CGFloat = 56
    /// A day with no value keeps a low neutral stub on the baseline so the row stays continuous.
    /// Nonzero bars start one point taller and in the accent, so small usage never reads as none.
    private static let emptyStubHeight: CGFloat = 3
    private static let minimumBarHeight: CGFloat = 4
    static let breakdownLayout = CostBreakdownLayout(
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
    /// Every provider's usage on each visible day, combined.
    private let bars: [CostDay]
    /// Each provider's own day behind a combined bar, keyed by day.
    private let parts: [String: [(provider: Provider, day: CostDay)]]
    private let barDayKeys: Set<String>
    private let unobservedDayKeys: Set<String>
    private let onLabelModeChanged: (CostChartLabelMode) -> Void
    private let onOpenPricing: (() -> Void)?
    private let isBreakdownExpanded: Bool
    private let breakdownOpenness: Double
    private let expandedBreakdownDayKey: String?
    private let onBreakdownExpandedChanged: (Bool, String?) -> Void

    init(
        snapshots: [CostSnapshot],
        previewHoveredDayKey: String? = nil,
        previewTodayDayKey: String? = nil,
        labelMode: CostChartLabelMode = .tokens,
        onLabelModeChanged: @escaping (CostChartLabelMode) -> Void = { _ in },
        isBreakdownExpanded: Bool = false,
        expandedBreakdownDayKey: String? = nil,
        previewToggleHovered: Bool = false,
        onBreakdownExpandedChanged: @escaping (Bool, String?) -> Void = { _, _ in },
        onOpenPricing: (() -> Void)? = nil
    ) {
        let todayKey = previewTodayDayKey ?? Formatters.dayKey(for: Date())
        let perProvider = snapshots.map { snapshot in
            (snapshot, CostChartHighlightPolicy.visibleDays(
                from: snapshot.days,
                todayDayKey: todayKey,
                maxBars: Self.maxBars
            ))
        }
        let dayKeys = perProvider.first?.1.map(\.dayKey) ?? []
        var parts: [String: [(provider: Provider, day: CostDay)]] = [:]
        for (snapshot, days) in perProvider {
            for day in days { parts[day.dayKey, default: []].append((snapshot.provider, day)) }
        }
        let bars = dayKeys.map { key in
            CostDay.combining((parts[key] ?? []).map(\.day), dayKey: key)
        }
        self.snapshots = snapshots
        self.todayDayKey = todayKey
        self.bars = bars
        self.parts = parts
        self.barDayKeys = Set(bars.map(\.dayKey))
        // A combined day is only known once every provider's scan covers it.
        self.unobservedDayKeys = perProvider.reduce(into: Set<String>()) { keys, entry in
            keys.formUnion(CostChartHighlightPolicy.unobservedDayKeys(
                visibleDays: entry.1,
                recordedDays: entry.0.days,
                scannedAt: entry.0.scannedAt
            ))
        }
        self._selectedLabelMode = State(initialValue: labelMode)
        self.parentLabelMode = labelMode
        self._hoveredDayKey = State(initialValue: previewHoveredDayKey)
        self._detailDayKey = State(initialValue: previewHoveredDayKey ?? bars.last?.dayKey)
        self.onLabelModeChanged = onLabelModeChanged
        self.onOpenPricing = onOpenPricing
        self.isBreakdownExpanded = isBreakdownExpanded
        self.breakdownOpenness = isBreakdownExpanded ? 1 : 0
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

            self.kpiRow
            self.chart
            self.dayDetail
            self.modelDisclosure
            self.estimateNote
        }
        .onChange(of: self.snapshots) { previous, current in
            self.reconcileSelection(providerChanged: previous.map(\.provider) != current.map(\.provider))
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
        // The Picker can supply its own animation transaction. Keep it out of the card layout.
        withTransaction(Transaction(animation: nil)) {
            self.selectedLabelMode = mode
            self.onLabelModeChanged(mode)
        }
    }

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 16) {
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
                    ? Formatters.tokens(self.windowTokens)
                    : self.costValue(self.windowCostAvailability),
                status: self.selectedLabelMode == .cost
                    ? self.status(self.windowCostAvailability) : nil
            )
        }
    }

    private var needsKPIStatusRow: Bool {
        self.isUnobserved(self.todayDayKey)
            || self.status(self.todayDay.costAvailability) != nil
            || self.status(self.windowCostAvailability) != nil
    }

    private var windowTokens: Int {
        self.snapshots.reduce(0) { $0 + $1.windowTokens }
    }

    private var windowCostAvailability: CostAvailability {
        CostAvailability.window(of: self.snapshots)
    }

    /// One provider keeps its own color; a mix of providers marks the day in a neutral tone.
    private var markColor: Color {
        self.snapshots.count == 1 ? Theme.accent(for: self.snapshots[0].provider) : Color.secondary
    }

    private func kpi(label: String, value: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            if self.needsKPIStatusRow {
                Text(status ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(status == nil ? 0 : 1)
                    .accessibilityHidden(status == nil)
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
            self.selectDay(day.dayKey)
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    if value > 0 {
                        self.stackedBar(day, value: value, height: max(Self.minimumBarHeight, height))
                            .opacity(CostChartHighlightPolicy.opacity(
                                dayKey: day.dayKey,
                                selectedDayKey: self.selectedDayKey
                            ))
                            .animation(CostChartHoverMotion.animation(
                                clearingHover: false,
                                reduceMotion: CostChartHoverMotion.systemReduceMotion
                            ), value: selected)
                            .padding(.horizontal, 2)
                    } else {
                        self.emptyStub(for: day)
                            .opacity(CostChartHighlightPolicy.opacity(
                                dayKey: day.dayKey,
                                selectedDayKey: self.selectedDayKey
                            ))
                            .animation(CostChartHoverMotion.animation(
                                clearingHover: false,
                                reduceMotion: CostChartHoverMotion.systemReduceMotion
                            ), value: selected)
                            .frame(height: Self.emptyStubHeight)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(height: Self.chartHeight)
                Capsule()
                    .fill(self.markColor)
                    .frame(width: 12, height: CostChartHoverMotion.markerHeight)
                    .opacity(selected ? 1 : 0)
                    .animation(CostChartHoverMotion.animation(
                        clearingHover: false,
                        reduceMotion: CostChartHoverMotion.systemReduceMotion
                    ), value: selected)
                    .frame(height: CostChartHoverMotion.markerBand)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle())
        .frame(maxWidth: .infinity)
        .focused(self.$focusedDayKey, equals: day.dayKey)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    self.markColor,
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
    }

    /// Each provider's share of the day, in the card's order from the baseline up. The first
    /// provider sits at the bottom so its segments line up across days.
    private func stackedBar(_ day: CostDay, value: Double, height: CGFloat) -> some View {
        let segments = (self.parts[day.dayKey] ?? []).compactMap { part -> (Provider, CGFloat)? in
            let share = CostChartHighlightPolicy.value(for: part.day, mode: self.selectedLabelMode)
            return share > 0 ? (part.provider, height * CGFloat(share / value)) : nil
        }
        return VStack(spacing: 0) {
            ForEach(segments.reversed(), id: \.0) { provider, segmentHeight in
                Rectangle()
                    .fill(Theme.accent(for: provider))
                    .frame(height: segmentHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(height: height)
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

    private var needsDayStatusRow: Bool {
        self.bars.contains { day in
            !self.isUnobserved(day.dayKey) && self.status(day.costAvailability) != nil
        }
    }

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(self.selectedDay.map { Formatters.dayLabel($0.dayKey) } ?? "Day")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let day = self.selectedDay, !self.isUnobserved(day.dayKey), self.snapshots.count > 1 {
                    self.providerSplit(day)
                } else if let day = self.selectedDay, !day.byModel.isEmpty {
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
                    .frame(height: 22, alignment: .top)
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
                    .frame(height: 22, alignment: .top)
                }
                if self.needsDayStatusRow {
                    let status = self.isUnobserved(day.dayKey)
                        ? nil : self.status(day.costAvailability)
                    Text(status.map { self.availabilityDetail($0, day.costAvailability) } ?? " ")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(height: 24, alignment: .top)
                        .opacity(status == nil ? 0 : 1)
                        .accessibilityHidden(status == nil)
                }
            }
            Divider()
        }
    }

    /// Each provider's own value for the day, beside the combined one.
    private func providerSplit(_ day: CostDay) -> some View {
        HStack(spacing: 8) {
            ForEach(self.parts[day.dayKey] ?? [], id: \.provider) { part in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accent(for: part.provider))
                        .frame(width: 5, height: 5)
                    Text(self.selectedLabelMode == .tokens
                        ? Formatters.tokens(part.day.tokens.total)
                        : self.costValue(part.day.costAvailability))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(part.provider.displayName) \(self.accessibleShare(part.day))")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func accessibleShare(_ day: CostDay) -> String {
        self.selectedLabelMode == .tokens
            ? "\(day.tokens.total) tokens"
            : self.costValue(day.costAvailability)
    }

    /// The selected day's models, grouped by provider in the card's order and ranked within each.
    private var rankedModels: [BreakdownRow] {
        guard let key = self.selectedDayKey else { return [] }
        return (self.parts[key] ?? []).flatMap { part in
            part.day.rankedModels(by: self.selectedLabelMode).enumerated().map { rank, entry in
                BreakdownRow(provider: part.provider, rank: rank, entry: entry)
            }
        }
    }

    private struct BreakdownRow {
        let provider: Provider
        /// Position within its provider, which sets how strongly its marker is drawn.
        let rank: Int
        let entry: (key: ModelUsageKey, model: String, usage: ModelDayUsage)
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
                        .animation(DisclosureMotion.open(
                            reduceMotion: CostChartHoverMotion.systemReduceMotion
                        ), value: self.breakdownOpenness)
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
                .frame(height: CGFloat(Self.breakdownLayout.toggleHeight))
            }
            .buttonStyle(ControlFeedbackStyle())
            .accessibilityLabel("Model breakdown")
            .accessibilityValue(self.isBreakdownExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(self.isBreakdownExpanded ? "Collapse model list" : "Expand model list")

            let ranked = self.rankedModels
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ranked, id: \.entry.key) { row in
                    self.breakdownRow(row.entry, provider: row.provider, index: row.rank)
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
        provider: Provider,
        index: Int
    ) -> some View {
        let name = self.breakdownLabel(entry.key)
        let amount = entry.usage.costUSD.map(Formatters.cost) ?? "No price"
        return HStack(spacing: 6) {
            Rectangle()
                .fill(Theme.accent(for: provider).opacity(max(0.3, 0.75 - Double(index) * 0.08)))
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
                if self.windowCostAvailability.unpricedTokens > 0,
                   let onOpenPricing = self.onOpenPricing {
                    Button("Pricing", action: onOpenPricing)
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .accessibilityHint("Open model rates for unpriced usage")
                }
            }
            if let status = self.status(self.windowCostAvailability) {
                Text(self.availabilityDetail(status, self.windowCostAvailability))
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
}
