import QuotaBarCore
import AppKit
import SwiftUI

/// The rates every cost estimate uses, read only. The four columns are the rates that move most;
/// the disclosure behind each row carries the rest of what the billing math reads.
struct PricingSettingsView: View {
    @ObservedObject var model: PricingTableModel
    /// The settings window keeps this pane mounted behind the General one so the tabs can
    /// cross-fade, so reading the scan cache waits for the tab to actually be opened.
    var isLoadEnabled = true
    /// Changes whenever the pane comes back into view, which rereads the rates.
    var reload = 0
    @State private var expandedGroups = Set(PricingGroup.allCases)
    /// The column under the pointer, so an unsorted header can show the arrow a click would
    /// give it. Without it a sorted-by-nothing header looks like plain text.
    @State private var hoveredSortField: PricingSortField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let paneWidth: CGFloat = 620
    private static let rateColumnWidth: CGFloat = 68
    /// A vertical scroll view only reserves room for its indicator once the content is tall
    /// enough to scroll. Folding a group crosses that line, so the table keeps the gutter in
    /// both states instead of letting every trailing column slide over by its width.
    private static let scrollerGutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    private static let tableContentWidth = Self.paneWidth - Self.scrollerGutter
    /// Click target for the per-row disclosure chevron, sized to the row rather than the glyph.
    private static let disclosureHitSize = CGSize(width: 22, height: 28)
    private static let detailLabelWidth: CGFloat = 138
    private static let claudePricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    private static let openAIPricingURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    private static let modelsDevURL = URL(string: "https://models.dev")!
    /// The gap between the vendor links, kept equal to the header's own padding.
    private static let linkSpacing: CGFloat = 12
    /// Claude and OpenAI are read by the accents their provider cards already carry. models.dev has
    /// no card in the app and no color of its own, so its arrow stays neutral.
    private static let modelsDevAccent = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider()
            if self.model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                self.table
            }
            Divider()
            self.footer
        }
        .frame(width: Self.paneWidth, height: 460)
        .task(id: [self.isLoadEnabled ? 1 : 0, self.reload]) {
            guard self.isLoadEnabled else { return }
            await self.model.load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model prices")
                .font(.system(size: 13, weight: .semibold))
            Text("USD per million tokens. Every cost is an estimate at these API prices. Claude "
                + "and OpenAI models use QuotaBar's built-in price book; other models use "
                + "models.dev. Expand a row for the one-hour cache write and the long-context tier.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(self.model.scanStatusMessages, id: \.self) { status in
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                    .disabled(self.model.isReadingUsage)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            // Three equal columns split by the panel's own margin, so the air between the buttons
            // and at either end of the row is the same. The row keeps the header's own symmetric
            // margins rather than the table's reserved scroller gutter, because the copy above it
            // does too. Only the arrow carries the vendor's color: brand-colored label text on a
            // system-gray button reads as a warning.
            HStack(spacing: Self.linkSpacing) {
                self.pricingLink("Claude API pricing", Self.claudePricingURL, Theme.accent(for: .claude))
                self.pricingLink("OpenAI API pricing", Self.openAIPricingURL, Theme.accent(for: .codex))
                self.pricingLink("models.dev", Self.modelsDevURL, Self.modelsDevAccent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(12)
    }

    private func pricingLink(_ title: String, _ url: URL, _ accent: Color) -> some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(accent)
                Text(title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(PricingGroup.allCases) { group in
                        self.group(group)
                    }
                } header: {
                    self.columnHeader
                }
            }
            // Hold the columns at one width and pin them left, so the gutter the scroll view
            // takes back when the table stops scrolling turns into empty space instead of a
            // sideways jump.
            .frame(width: Self.tableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Hand-rolled to keep the chevron and the content on the same brief opening curve.
    private func group(_ group: PricingGroup) -> some View {
        let rows = self.model.rows(in: group)
        let isExpanded = self.expandedGroups.contains(group)
        return VStack(alignment: .leading, spacing: 0) {
            self.groupHeader(group, count: rows.count, isExpanded: isExpanded)
            if isExpanded {
                if rows.isEmpty {
                    Text("No models")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .transition(self.rowTransition)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            self.row(row)
                            if self.model.isExpanded(row.id) {
                                self.detail(row)
                                    .transition(self.detailTransition)
                            }
                            Divider().padding(.leading, 28)
                        }
                        .transition(self.rowTransition)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func groupHeader(_ group: PricingGroup, count: Int, isExpanded: Bool) -> some View {
        Button {
            withAnimation(DisclosureMotion.open(reduceMotion: self.reduceMotion)) {
                self.expansionBinding(for: group).wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                DisclosureChevron(isOpen: isExpanded, size: 11, reduceMotion: self.reduceMotion)
                    .foregroundStyle(.primary)
                    .frame(width: 6)
                Text(group.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            // The whole header row is the control, not just the chevron.
            .frame(maxWidth: .infinity, minHeight: Self.disclosureHitSize.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
    }

    /// All rows appear together as the group changes height.
    private var rowTransition: AnyTransition {
        guard !self.reduceMotion else { return .identity }
        return .opacity.animation(DisclosureMotion.openCurve)
    }

    /// The per-row disclosure is one block, not a list, so it has no beat of its own to keep.
    private var detailTransition: AnyTransition {
        guard !self.reduceMotion else { return .identity }
        return .opacity.animation(DisclosureMotion.openCurve)
    }

    private func expansionBinding(for group: PricingGroup) -> Binding<Bool> {
        Binding(
            get: { self.expandedGroups.contains(group) },
            set: { expanded in
                if expanded {
                    self.expandedGroups.insert(group)
                } else {
                    self.expandedGroups.remove(group)
                }
            }
        )
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Self.disclosureHitSize.width)
            self.sortHeader("Model", .model, alignment: .leading)
            self.sortHeader("Input", .input)
            self.sortHeader("Output", .output)
            self.sortHeader("Cache w", .cacheWrite)
            self.sortHeader("Cache r", .cacheRead)
            // The default order is a sort like any other, but it has no column of its own to
            // light up, so this control carries the highlight while it is the one in force.
            Button {
                self.model.resetSort()
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(self.model.sort.isDefault ? Color.primary : Color.secondary)
                    .frame(width: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
            .frame(width: 22)
            .help("Back to the default order: API whitelist fixed order; Others most-used first")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background)
    }

    /// A clickable column title. The arrow only shows on the column in force, so the header
    /// reads as one sorted column rather than five controls competing for attention.
    private func sortHeader(
        _ title: String,
        _ field: PricingSortField,
        alignment: HorizontalAlignment = .trailing
    ) -> some View {
        let sort = self.model.sort
        let isActive = sort.field == field
        let leading = alignment == .leading
        // Hovering an unsorted column previews the direction its click would land on.
        let preview = PricingSortPolicy.next(after: sort, tapping: field)
        let arrow = self.sortArrow(
            ascending: isActive ? sort.ascending : preview.ascending,
            opacity: isActive ? 1 : (self.hoveredSortField == field ? 0.4 : 0)
        )

        return Button {
            self.model.toggleSort(field)
        } label: {
            HStack(spacing: 2) {
                // The arrow sits on the outside of the label, so the numbers underneath a rate
                // column stay flush with their title whichever column is sorted.
                if !leading { arrow }
                Text(title)
                if leading { arrow }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(
                maxWidth: leading ? .infinity : Self.rateColumnWidth,
                alignment: leading ? .leading : .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
        .frame(maxWidth: leading ? .infinity : Self.rateColumnWidth)
        .onHover { self.hoveredSortField = $0 ? field : nil }
        .help(self.sortHint(title, field))
    }

    private func sortArrow(ascending: Bool, opacity: Double) -> some View {
        Image(systemName: ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .opacity(opacity)
    }

    private func sortHint(_ title: String, _ field: PricingSortField) -> String {
        let next = PricingSortPolicy.next(after: self.model.sort, tapping: field)
        return next.ascending ? "Sort by \(title), ascending" : "Sort by \(title), descending"
    }

    private func row(_ row: PricingRow) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(DisclosureMotion.open(reduceMotion: self.reduceMotion)) {
                    self.model.toggleExpanded(row.id)
                }
            } label: {
                DisclosureChevron(isOpen: self.model.isExpanded(row.id), reduceMotion: self.reduceMotion)
                    .foregroundStyle(.secondary)
                    // A 9pt chevron is a hard target to hit; the hit area covers the whole
                    // column instead of just the glyph.
                    .frame(width: Self.disclosureHitSize.width, height: Self.disclosureHitSize.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
            .frame(width: Self.disclosureHitSize.width)
            .help("One-hour cache write and long-context rates")

            Button {
                withAnimation(DisclosureMotion.open(reduceMotion: self.reduceMotion)) {
                    self.model.toggleExpanded(row.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.model)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if !self.model.hasLoadedUsage {
                            Text("Usage unavailable")
                        } else if row.usageTokens > 0 {
                            Text("\(Formatters.tokens(row.usageTokens)) tokens")
                        } else {
                            Text("Not used locally")
                        }
                        switch row.source {
                        case .modelsDev?:
                            Text("· models.dev")
                        case nil where row.seenInLogs:
                            // The rows whose tokens count toward totals but not toward cost.
                            Text("· unpriced").foregroundStyle(.orange)
                        default:
                            EmptyView()
                        }
                        if row.hasLongContextTier {
                            Text("· 2 tiers").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("One-hour cache write and long-context rates")

            self.rateCell(row.input)
            self.rateCell(row.output)
            self.rateCell(row.cacheWrite)
            self.rateCell(row.cacheRead)
            // Keeps the rates under their headers, which end with the sort reset control.
            Color.clear.frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Everything else the cost math reads: the one-hour cache write, and the second tier that
    /// kicks in above a per-request token count.
    private func detail(_ row: PricingRow) -> some View {
        let rates = row.rates
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("1-hour cache write")
                    .frame(width: Self.detailLabelWidth, alignment: .leading)
                self.rateCell(rates.map { $0.cacheWrite1hRate(longContext: false) })
                if rates != nil, rates?.cacheWrite1h == nil {
                    Text("2× input, the ratio Anthropic publishes.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Long-context threshold")
                    .frame(width: Self.detailLabelWidth, alignment: .leading)
                Text(rates?.thresholdTokens.map { Formatters.tokens($0) } ?? "—")
                    .monospacedDigit()
                    .frame(width: Self.rateColumnWidth, alignment: .trailing)
                Text(rates?.thresholdTokens == nil
                     ? "The model has a single tier."
                     : "Tokens in one request.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if let rates, rates.thresholdTokens != nil {
                HStack(alignment: .bottom, spacing: 8) {
                    Text("Rates above it")
                        .frame(width: Self.detailLabelWidth, alignment: .leading)
                    self.captionedCell("Input", rates.inputAbove ?? rates.input)
                    self.captionedCell("Output", rates.outputAbove ?? rates.output)
                    self.captionedCell("Cache w", rates.cacheWriteAbove ?? rates.cacheWrite)
                    self.captionedCell("Cache 1h", rates.cacheWrite1hRate(longContext: true))
                    self.captionedCell("Cache r", rates.cacheReadAbove ?? rates.cacheRead)
                }
            }

            if let source = row.source {
                Text(source == .priceBook
                     ? "From QuotaBar's built-in price book."
                     : "From models.dev, at the model maker's listed price when it has one.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    private func captionedCell(_ caption: String, _ value: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            self.rateCell(value)
        }
    }

    private func rateCell(_ value: Double?) -> some View {
        Text(PricingTableModel.text(value))
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .frame(width: Self.rateColumnWidth, alignment: .trailing)
    }

    private var footer: some View {
        Text(self.footerText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private var footerText: String {
        let unpriced = "Unpriced models count toward token totals but not cost."
        guard self.model.modelsDevEnabled else {
            return "models.dev prices are off in General, so only Claude and OpenAI models are priced. " + unpriced
        }
        guard let fetchedAt = self.model.modelsDevFetchedAt else {
            return "models.dev prices have not been downloaded yet. " + unpriced
        }
        return "models.dev prices updated \(Formatters.relativeAge(since: fetchedAt)). " + unpriced
    }
}
