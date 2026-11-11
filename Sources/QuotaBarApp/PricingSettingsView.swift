import QuotaBarCore
import AppKit
import SwiftUI

/// The rates every cost estimate uses, read only. Each source has its own card, with its models
/// grouped by vendor and the ones the local logs spend tokens on first; a row opens in place to
/// show the rest of what the billing math reads for that model.
struct PricingSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: PricingTableModel
    /// The settings window keeps this pane mounted behind the General one so the panes can
    /// cross-fade, so reading the scan cache waits for the pane to actually be opened.
    var isLoadEnabled = true
    /// Changes whenever the pane comes back into view, which rereads the rates.
    var reload = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsNow) private var now
    @FocusState private var isTableFocused: Bool

    private static let rateColumnWidth: CGFloat = 76
    /// Room for the overlay scroller beside the cards.
    private static let scrollGutter: CGFloat = 18
    private static let claudePricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    private static let openAIPricingURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    private static let modelsDevURL = URL(string: "https://models.dev")!

    var body: some View {
        SettingsPane("Pricing") {
            SettingsSearchField(prompt: "Search models", text: self.$model.searchText)
                .frame(width: 200)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                self.table
                Divider()
                self.footer
            }
            .padding(.bottom, 16)
        }
        .task(id: [self.isLoadEnabled ? 1 : 0, self.reload, self.settings.modelsDevPricing ? 1 : 0]) {
            guard self.isLoadEnabled else { return }
            await self.model.load()
        }
        .onChange(of: self.reload) { self.model.foldAll() }
    }

    // MARK: - Table

    /// models.dev keeps its heading with nothing to list, because the heading holds its switch.
    private var sections: [PricingSectionGroup] {
        var sections = self.model.listSections
        guard !self.model.isSearching, !sections.contains(where: { $0.section == .modelsDev }) else {
            return sections
        }
        let index = sections.firstIndex { $0.section == .unpriced } ?? sections.endIndex
        sections.insert(PricingSectionGroup(section: .modelsDev, vendors: []), at: index)
        return sections
    }

    private func sectionHeader(_ section: PricingSection) -> some View {
        SettingsSectionHeader(section.rawValue) {
            switch section {
            case .builtIn:
                Label("Always used", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Built-in prices always apply; models.dev only fills in models they do not list.")
            case .modelsDev:
                Text(self.modelsDevStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("Price other models with models.dev", isOn: self.$settings.modelsDevPricing)
                    .toggleStyle(.switch)
                    .labelsHidden()
            case .unpriced:
                EmptyView()
            }
        }
    }

    /// Names the rates of a vendor's rows, so a folded list carries no empty columns.
    private var columnCaptions: some View {
        HStack(spacing: 0) {
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Input", "Output", "Cache write", "Cache read"], id: \.self) { title in
                Text(title)
                    .frame(width: Self.rateColumnWidth, alignment: .trailing)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholder(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .settingsGroup()
    }

    private var table: some View {
        let sections = self.sections
        return Group {
            if self.model.isLoading {
                self.placeholder {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if sections.isEmpty {
                self.placeholder {
                    Text("No models match.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                self.sectionHeader(section.section)
                                    .padding(.top, index == 0 ? 0 : 22)
                                    .padding(.bottom, 8)
                                if !section.vendors.isEmpty {
                                    self.sectionCard(section)
                                }
                            }
                        }
                        // Reserve a gutter even while the overlay indicator is hidden.
                        .padding(.trailing, Self.scrollGutter)
                        .padding(.bottom, 12)
                        .background(PricingScrollStyle())
                    }
                    // Rows fade out into the footer instead of being cut by it.
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 12)
                        }
                    }
                    .onChange(of: self.model.selectedRowID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
                .focusable()
                .focused(self.$isTableFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    switch direction {
                    case .up: self.moveSelection(by: -1)
                    case .down: self.moveSelection(by: 1)
                    default: break
                    }
                }
                // The gutter comes out of the pane's margin, so the cards end where the search
                // field and the footer rule do.
                .padding(.trailing, -Self.scrollGutter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionCard(_ section: PricingSectionGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(section.vendors.enumerated()), id: \.element.id) { index, vendor in
                if index > 0 { Divider() }
                self.vendorHeader(vendor)
                if self.model.isOpen(vendor) {
                    Divider()
                    self.columnCaptions
                    ForEach(vendor.rows) { row in
                        Divider()
                        self.tableRow(row)
                            .id(row.id)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .settingsGroup()
    }

    private func vendorHeader(_ vendor: PricingVendorGroup) -> some View {
        let isOpen = self.model.isOpen(vendor)
        return Button {
            self.model.toggle(vendor)
            self.isTableFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: isOpen)
                    .frame(width: 10)
                Text(vendor.vendor)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if vendor.usageTokens > 0 {
                    Text("\(Formatters.tokens(vendor.usageTokens)) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion, pressScale: CardMotion.rowPressScale))
        .settingsRowHover()
        .disabled(self.model.isSearching)
        .accessibilityLabel("\(vendor.vendor), \(vendor.rows.count == 1 ? "1 model" : "\(vendor.rows.count) models")")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    private func tableRow(_ row: PricingRow) -> some View {
        let isOpen = row.id == self.model.selectedRowID
        let isUsed = row.usageTokens > 0
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                self.model.selectedRowID = isOpen ? nil : row.id
                self.isTableFocused = true
            } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Self.accent(for: row.group))
                            .opacity(isUsed ? 1 : 0.45)
                            .frame(width: 7, height: 7)
                            .help(isUsed ? "Used on this Mac" : "Not used on this Mac")
                        // The same name the menu card uses, with the id the logs carry beside it.
                        Text(Formatters.modelName(row.model))
                            .foregroundStyle(isUsed || isOpen ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if Formatters.modelName(row.model) != row.model {
                            Text(row.model)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if row.seenInLogs, !row.isPriced {
                            Text("unpriced")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    self.rateCell(row.input)
                    self.rateCell(row.output)
                    self.rateCell(row.cacheWrite)
                    self.rateCell(row.cacheRead)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion, pressScale: CardMotion.rowPressScale))
            .settingsRowHover()
            .accessibilityAddTraits(isOpen ? [.isSelected] : [])
            if isOpen {
                self.rowDetail(row)
                    .padding(.leading, 26)
                    .padding(.trailing, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.primary.opacity(isOpen ? 0.05 : 0))
    }

    private func rateCell(_ value: Double?, isVariant: Bool = false) -> some View {
        Text(PricingTableModel.text(value))
            .monospacedDigit()
            .foregroundStyle(value == nil ? .tertiary : isVariant ? .secondary : .primary)
            .lineLimit(1)
            .frame(width: Self.rateColumnWidth, alignment: .trailing)
    }

    private func moveSelection(by offset: Int) {
        let rows = self.model.visibleRows
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == self.model.selectedRowID }) else {
            self.model.selectedRowID = rows.first?.id
            return
        }
        self.model.selectedRowID = rows[max(0, min(rows.count - 1, current + offset))].id
    }

    // MARK: - Detail

    private func rowDetail(_ row: PricingRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Rates first, in the row's columns; where they come from closes the panel.
            self.secondaryRates(row)
            HStack(spacing: 4) {
                Text(self.usageLine(row))
                Text("·")
                Text(self.sourceLine(row))
                if let link = Self.link(for: row) {
                    Text("·")
                    Link(destination: link.url) {
                        Text("\(link.title) ↗")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.top, -2)
        }
    }

    /// Everything else the cost math reads: the one-hour cache write, the second tier that kicks
    /// in above a per-request token count, and how much of the model this Mac has recorded.
    @ViewBuilder
    private func secondaryRates(_ row: PricingRow) -> some View {
        let rates = row.rates
        // Every rate sits in the row's own columns; prose spans the row on its own line.
        VStack(alignment: .leading, spacing: 8) {
            self.gridLine(rates: [nil, nil, rates.map { $0.cacheWrite1hRate(longContext: false) }, nil]) {
                HStack(spacing: 6) {
                    Text("1-hour cache write")
                    if rates != nil, rates?.cacheWrite1h == nil {
                        Text("2× input")
                            .foregroundStyle(.secondary)
                            .help("Not listed, so priced at 2× input, the ratio Anthropic publishes.")
                    }
                }
            }
            if let rates, let threshold = rates.thresholdTokens {
                self.gridLine(rates: [
                    rates.inputAbove ?? rates.input,
                    rates.outputAbove ?? rates.output,
                    rates.cacheWriteAbove ?? rates.cacheWrite,
                    rates.cacheReadAbove ?? rates.cacheRead,
                ]) {
                    Text("Above \(Formatters.tokens(threshold)) per request")
                }
                .help("1-hour cache write above the threshold: \(PricingTableModel.text(rates.cacheWrite1hRate(longContext: true)))")
            } else if rates != nil {
                Text("One rate at every request size")
                    .foregroundStyle(.secondary)
            }
            if row.seenInLogs, !row.isPriced {
                Text(self.unpricedReason(row))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    /// A label over the free width, then one cell per rate column; nil leaves a column empty.
    private func gridLine(rates: [Double?], @ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 0) {
            label()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(rates.enumerated()), id: \.offset) { _, rate in
                if let rate {
                    self.rateCell(rate, isVariant: true)
                } else {
                    Color.clear.frame(width: Self.rateColumnWidth, height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }


    private func usageLine(_ row: PricingRow) -> String {
        if !self.model.hasLoadedUsage { return "Local usage unavailable" }
        return row.usageTokens > 0 ? "\(Formatters.tokens(row.usageTokens)) tokens on this Mac" : "Not used on this Mac"
    }

    private func sourceLine(_ row: PricingRow) -> String {
        switch row.source {
        case .priceBook?: "Built-in price book"
        case .modelsDev?: "models.dev"
        case nil: "Unpriced"
        }
    }

    private func unpricedReason(_ row: PricingRow) -> String {
        guard row.group == .others, !self.model.modelsDevEnabled else {
            return "No source prices this model today. Its tokens count toward totals but not cost."
        }
        return "models.dev prices are off, so its tokens count toward totals but not cost."
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(self.model.scanStatusMessages, id: \.self) { status in
                Label(status, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = self.model.usageReadError {
                HStack(alignment: .top, spacing: 8) {
                    Label(
                        self.model.hasLoadedUsage
                            ? "Usage refresh failed. Showing the last available usage."
                            : "Local usage is unavailable. Rates are still shown.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .help(error)
                    Spacer(minLength: 0)
                    Button(self.model.isReadingUsage ? "Retrying…" : "Retry") {
                        Task { await self.model.retryUsage() }
                    }
                    .controlSize(.small)
                    .disabled(self.model.isReadingUsage)
                }
            }
            Text("Rates are USD per 1M tokens at API list prices. A bright dot marks a model used here.")
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var modelsDevStatus: String {
        guard self.model.modelsDevEnabled else { return "Off" }
        guard let fetchedAt = self.model.modelsDevFetchedAt else { return "Not downloaded yet" }
        return "Updated \(Formatters.relativeAge(since: fetchedAt, now: self.now))"
    }

    // MARK: - Sources

    /// Claude and Codex rows wear their provider's accent; models.dev has no card in the app and
    /// no color of its own, so Others stay neutral.
    private static func accent(for group: PricingGroup) -> Color {
        switch group {
        case .claude: Theme.accent(for: .claude)
        case .codex: Theme.accent(for: .codex)
        case .others: Color.secondary
        }
    }

    private static func link(for row: PricingRow) -> (title: String, url: URL)? {
        switch (row.source, row.group) {
        case (.priceBook?, .claude): ("Claude API pricing", Self.claudePricingURL)
        case (.priceBook?, _): ("OpenAI API pricing", Self.openAIPricingURL)
        case (.modelsDev?, _): ("Open models.dev", Self.modelsDevURL)
        case (nil, _): nil
        }
    }
}

/// Keep the pricing indicator on a transparent track, including with always-visible scrollers.
private struct PricingScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollStyleView {
        ScrollStyleView()
    }

    func updateNSView(_ view: ScrollStyleView, context: Context) {
        view.applyStyle()
    }

    final class ScrollStyleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.applyStyle()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            self.applyStyle()
        }

        func applyStyle() {
            guard let scrollView = self.enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
        }
    }
}

/// AppKit's search field, with its magnifier and clear button, for filtering a settings list.
struct SettingsSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = self.prompt
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != self.text { field.stringValue = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: self.$text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            self.text.wrappedValue = field.stringValue
        }
    }
}
