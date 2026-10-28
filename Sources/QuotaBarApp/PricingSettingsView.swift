import QuotaBarCore
import AppKit
import SwiftUI

/// The rates every cost estimate uses, read only. The list on the left is every model, the ones
/// the local logs spend tokens on first; the side on the right carries everything the billing
/// math reads for the one picked, so nothing hides behind a disclosure.
struct PricingSettingsView: View {
    @ObservedObject var model: PricingTableModel
    /// The settings window keeps this pane mounted behind the General one so the tabs can
    /// cross-fade, so reading the scan cache waits for the tab to actually be opened.
    var isLoadEnabled = true
    /// Changes whenever the pane comes back into view, which rereads the rates.
    var reload = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isListFocused: Bool

    private static let listWidth: CGFloat = 236
    private static let rateTileWidth: CGFloat = 76
    private static let detailLabelWidth: CGFloat = 132
    private static let claudePricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    private static let openAIPricingURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    private static let modelsDevURL = URL(string: "https://models.dev")!

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.top, 10)
            HStack(spacing: 0) {
                self.list
                    .frame(width: Self.listWidth)
                Divider()
                self.detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: SettingsView.paneWidth, height: SettingsView.paneHeight)
        .task(id: [self.isLoadEnabled ? 1 : 0, self.reload]) {
            guard self.isLoadEnabled else { return }
            await self.model.load()
        }
    }

    // MARK: - List

    private var list: some View {
        let rows = self.model.listRows
        let selected = self.model.selectedRow?.id
        let busiest = max(1, rows.map(\.usageTokens).max() ?? 0)
        return VStack(spacing: 0) {
            TextField("Search models", text: self.$model.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if self.model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                Text("No models match.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                self.listRow(row, isSelected: row.id == selected, busiest: busiest)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: self.model.selectedRowID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
                .focusable()
                .focused(self.$isListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    switch direction {
                    case .up: self.moveSelection(by: -1)
                    case .down: self.moveSelection(by: 1)
                    default: break
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private func listRow(_ row: PricingRow, isSelected: Bool, busiest: Int) -> some View {
        let isUsed = row.usageTokens > 0
        return Button {
            self.model.selectedRowID = row.id
            self.isListFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Self.accent(for: row.group))
                        .opacity(isUsed ? 1 : 0.45)
                        .frame(width: 7, height: 7)
                    Text(row.model)
                        .font(.system(size: 12))
                        .foregroundStyle(isUsed || isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    self.listTrailing(row)
                }
                if isUsed {
                    Capsule()
                        .fill(Theme.progressTrack)
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Self.accent(for: row.group))
                                    .frame(width: max(3, geometry.size.width
                                        * CGFloat(row.usageTokens) / CGFloat(busiest)))
                            }
                        }
                        .padding(.leading, 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.11 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion, pressScale: CardMotion.rowPressScale))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Tokens for a model in use, a flag for one whose tokens count toward no cost, a dash for
    /// one the logs never named.
    @ViewBuilder
    private func listTrailing(_ row: PricingRow) -> some View {
        if row.seenInLogs, !row.isPriced {
            Text("unpriced")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if !self.model.hasLoadedUsage {
            EmptyView()
        } else if row.usageTokens > 0 {
            Text(Formatters.tokens(row.usageTokens))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func moveSelection(by offset: Int) {
        let rows = self.model.listRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == self.model.selectedRow?.id } ?? 0
        let next = max(0, min(rows.count - 1, current + offset))
        self.model.selectedRowID = rows[next].id
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = self.model.selectedRow {
                self.detailBody(row)
            } else if !self.model.isLoading {
                Text("Pick a model to see its rates.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            self.footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func detailBody(_ row: PricingRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.model)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(self.sourceLine(row))
                    if let link = Self.link(for: row) {
                        Text("·")
                        Link(destination: link.url) {
                            Text("\(link.title) ↗")
                                .underline()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                self.rateTile("Input", row.input)
                self.rateTile("Output", row.output)
                self.rateTile("Cache write", row.cacheWrite)
                self.rateTile("Cache read", row.cacheRead)
            }

            self.secondaryRates(row)
        }
    }

    private func rateTile(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(PricingTableModel.text(value))
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Everything else the cost math reads: the one-hour cache write, the second tier that kicks
    /// in above a per-request token count, and how much of the model this Mac has recorded.
    @ViewBuilder
    private func secondaryRates(_ row: PricingRow) -> some View {
        let rates = row.rates
        VStack(alignment: .leading, spacing: 8) {
            self.detailLine("1-hour cache write") {
                Text(PricingTableModel.text(rates.map { $0.cacheWrite1hRate(longContext: false) }))
                    .monospacedDigit()
                if rates != nil, rates?.cacheWrite1h == nil {
                    Text("2× input")
                        .foregroundStyle(.secondary)
                        .help("Not listed, so priced at 2× input, the ratio Anthropic publishes.")
                }
            }
            self.detailLine("Long-context tier") {
                if let threshold = rates?.thresholdTokens {
                    Text("Above \(Formatters.tokens(threshold)) tokens in one request")
                } else {
                    Text(rates == nil ? "—" : "Single tier")
                        .foregroundStyle(rates == nil ? .tertiary : .primary)
                }
            }
            if let rates, rates.thresholdTokens != nil {
                HStack(spacing: 0) {
                    self.aboveCell("Input", rates.inputAbove ?? rates.input)
                    self.aboveCell("Output", rates.outputAbove ?? rates.output)
                    self.aboveCell("Cache w", rates.cacheWriteAbove ?? rates.cacheWrite)
                    self.aboveCell("Cache 1h", rates.cacheWrite1hRate(longContext: true))
                    self.aboveCell("Cache r", rates.cacheReadAbove ?? rates.cacheRead)
                }
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rates above the threshold")
            }
            self.detailLine("Recorded locally") {
                if !self.model.hasLoadedUsage {
                    Text("Usage unavailable").foregroundStyle(.secondary)
                } else if row.usageTokens > 0 {
                    Text("\(Formatters.tokens(row.usageTokens)) tokens")
                } else {
                    Text("Not used on this Mac").foregroundStyle(.secondary)
                }
            }
            if row.seenInLogs, !row.isPriced {
                Text(self.unpricedReason(row))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    /// One of the rates above the long-context threshold.
    private func aboveCell(_ caption: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(PricingTableModel.text(value))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func detailLine(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: Self.detailLabelWidth, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) { value() }
            Spacer(minLength: 0)
        }
    }

    private func sourceLine(_ row: PricingRow) -> String {
        switch row.source {
        case .priceBook?: "Built-in price book · USD per 1M tokens"
        case .modelsDev?: "models.dev · USD per 1M tokens"
        case nil: "Unpriced"
        }
    }

    private func unpricedReason(_ row: PricingRow) -> String {
        guard row.group == .others, !self.model.modelsDevEnabled else {
            return "No source prices this model today. Its tokens count toward totals but not cost."
        }
        return "models.dev prices are off in General, so its tokens count toward totals but not cost."
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
            Text(self.footerText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var footerText: String {
        let estimate = "Costs are estimates at API list prices."
        guard self.model.modelsDevEnabled else {
            return "\(estimate) models.dev prices are off in General."
        }
        guard let fetchedAt = self.model.modelsDevFetchedAt else {
            return "\(estimate) models.dev prices have not been downloaded yet."
        }
        return "\(estimate) models.dev prices updated \(Formatters.relativeAge(since: fetchedAt))."
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
        case (.modelsDev?, _): ("models.dev", Self.modelsDevURL)
        case (nil, _): nil
        }
    }
}
