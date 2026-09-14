import QuotaBarCore
import AppKit
import SwiftUI

/// Editable rate table. Rows are pre-filled with the rates currently in force, so editing one
/// is a correction rather than a blank form. The four columns are the rates that move most;
/// the disclosure behind each row carries the rest of what the billing math reads.
struct PricingSettingsView: View {
    @ObservedObject var model: PricingEditorModel
    /// The settings window keeps this pane mounted behind the General one so the tabs can
    /// cross-fade, so the scan and the catalog refresh wait for the tab to actually be opened.
    var isLoadEnabled = true
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
    private static let openRouterPricingURL = URL(string: "https://openrouter.ai/models")!
    /// The gap between the vendor links, kept equal to the header's own padding.
    private static let linkSpacing: CGFloat = 12
    /// Claude and OpenAI are read by the accents their provider cards already carry. OpenRouter has
    /// no card in the app, so it borrows the indigo from its own site, held at the same saturation.
    private static let openRouterAccent = Color(red: 124 / 255, green: 118 / 255, blue: 214 / 255)

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
        .task(id: self.isLoadEnabled) {
            guard self.isLoadEnabled else { return }
            await self.model.load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model prices")
                .font(.system(size: 13, weight: .semibold))
            Text("USD per million tokens. Expand a row for the one-hour cache write and the "
                + "long-context tier. Edits are saved as overrides, so models you leave alone "
                + "keep following the built-in table and the models.dev catalog.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(self.model.externalScanStatuses, id: \.self) { status in
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Three equal columns split by the panel's own margin, so the air between the buttons
            // and at either end of the row is the same. The row keeps the header's own symmetric
            // margins rather than the table's reserved scroller gutter, because the copy above it
            // does too. Only the arrow carries the vendor's color: brand-colored label text on a
            // system-gray button reads as a warning.
            HStack(spacing: Self.linkSpacing) {
                self.pricingLink("Claude API pricing", Self.claudePricingURL, Theme.accent(for: .claude))
                self.pricingLink("OpenAI API pricing", Self.openAIPricingURL, Theme.accent(for: .codex))
                self.pricingLink("OpenRouter API pricing", Self.openRouterPricingURL, Self.openRouterAccent)
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
                            self.rowErrors(row)
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
                        if row.usageTokens > 0 {
                            Text("\(Formatters.tokens(row.usageTokens)) tokens")
                        } else {
                            Text("Not used locally")
                        }
                        // The rows that actually change a number on screen.
                        if row.seenInLogs, !row.isPriced {
                            Text("· unpriced").foregroundStyle(.orange)
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

            self.rateField(row.id, .input)
            self.rateField(row.id, .output)
            self.rateField(row.id, .cacheWrite)
            self.rateField(row.id, .cacheRead)

            Menu {
                Button(row.hasDefault ? "Restore default rate" : "Clear custom rate") {
                    self.model.reset(id: row.id)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Price actions for \(row.model)")
            .accessibilityLabel("Price actions for \(row.model)")
            .disabled(!self.model.canRestoreDefault(id: row.id) || self.model.saveStatus == .saving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Everything else the cost math reads: the one-hour cache write, and the second tier that
    /// kicks in above a per-request token count.
    private func detail(_ row: PricingRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("1-hour cache write")
                    .frame(width: Self.detailLabelWidth, alignment: .leading)
                self.rateField(row.id, .cacheWrite1h, placeholder: Self.rate(row.derivedCacheWrite1h))
                Text("Empty bills it at 2× input, the ratio Anthropic publishes.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Long-context threshold")
                    .frame(width: Self.detailLabelWidth, alignment: .leading)
                self.rateField(row.id, .thresholdTokens, placeholder: "—")
                Text("Tokens in one request. Empty means the model has a single tier.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Text("Rates above it")
                    .frame(width: Self.detailLabelWidth, alignment: .leading)
                self.captionedField("Input", row.id, .inputAbove)
                self.captionedField("Output", row.id, .outputAbove)
                self.captionedField("Cache w", row.id, .cacheWriteAbove)
                self.captionedField(
                    "Cache 1h",
                    row.id,
                    .cacheWrite1hAbove,
                    placeholder: Self.rate(row.derivedCacheWrite1hAbove)
                )
                self.captionedField("Cache r", row.id, .cacheReadAbove)
            }

            Text("An empty above-threshold rate falls back to the base rate on its left.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    private func captionedField(
        _ caption: String,
        _ id: String,
        _ field: PricingField,
        placeholder: String = "—"
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            self.rateField(id, field, placeholder: placeholder)
        }
    }

    private func rateField(
        _ id: String,
        _ field: PricingField,
        placeholder: String = "—"
    ) -> some View {
        RateField(
            placeholder,
            text: self.model.binding(for: id, keyPath: field.keyPath),
            accessibilityLabel: "\(self.model.modelName(for: id)), \(field.title), \(field.unit)",
            error: self.model.error(for: id, field: field),
            isDisabled: self.model.saveStatus == .saving
        )
    }

    private func rowErrors(_ row: PricingRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(PricingField.allCases, id: \.self) { field in
                if let error = self.model.error(for: row.id, field: field) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 10))
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .padding(.bottom, self.model.validationErrors[row.id] == nil ? 0 : 6)
    }

    private static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return PricingEditorModel.text(value)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if self.model.invalidFieldCount > 0 {
                    Label("\(self.model.invalidFieldCount) invalid field\(self.model.invalidFieldCount == 1 ? "" : "s"). Changes not saved.",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text("Your saved prices are unchanged.").foregroundStyle(.secondary)
                } else if case .failed(let error) = self.model.saveStatus {
                    Label("Save failed: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text("Your edits are still here. Try Save again.").foregroundStyle(.secondary)
                } else {
                    Text(self.footerHint).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Discard") { self.model.discard() }
                .disabled(!self.model.hasUnsavedChanges || self.model.saveStatus == .saving)
            Button("Save") {
                Task { await self.model.save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!self.model.hasUnsavedChanges || self.model.invalidFieldCount > 0
                      || self.model.saveStatus == .saving)
        }
        .padding(12)
    }

    private var footerHint: String {
        if self.model.saveStatus == .saving {
            return "Saving…"
        }
        if self.model.hasUnsavedChanges {
            return "Unsaved changes. New rates apply only to usage recorded after saving."
        }
        if self.model.saveStatus == .saved {
            return "Saved. Usage already recorded keeps the prices it was billed at; "
                + "the new rates apply from here on."
        }
        return "Saved rates apply to new usage only — past days keep the prices they were "
            + "scanned with. Unpriced models stay out of cost totals."
    }
}
