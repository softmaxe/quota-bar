import QuotaBarCore
import AppKit
import SwiftUI

/// The 280 pt overview hosted inside the status item's popover: every provider's quota windows,
/// one above the other, then their local usage combined. Each provider's header opens its detail
/// in place, one provider at a time.
struct MenuCardView: View {
    let displays: [Provider: ProviderDisplay]
    var refreshingProviders: Set<Provider> = []
    /// The provider whose detail is open. Held by the menu, which starts every opening collapsed.
    var expandedProvider: Provider?
    var onProviderToggled: (Provider) -> Void = { _ in }
    /// False for the offscreen card dump, which captures a stable frame without transitions.
    var animatesFill = true
    /// Windows that reset and the final remaining percentage observed before each reset.
    var recoveries: [Provider: [QuotaWindowKind: QuotaRecoveryEvent]] = [:]
    /// Bumped per window, so one reset cannot replay the other window's finished animation.
    var celebrationTokens: [Provider: [QuotaWindowKind: Int]] = [:]
    /// Captured when the card is rebuilt so relative labels can be tested without wall-clock waits.
    var now = Date()
    var costChartLabelMode = CostChartLabelMode.tokens
    var onCostChartLabelModeChanged: (CostChartLabelMode) -> Void = { _ in }
    /// Whether the cost breakdown is showing every model of the selected day. It is held by the
    /// menu rather than by the card, because opening the list is the one click that changes the
    /// card's height and the hosting view has to be resized around it.
    var isCostBreakdownExpanded = false
    /// The day being held open, shared with the controller's off-screen height probe.
    var expandedCostBreakdownDayKey: String?
    var onCostBreakdownExpandedChanged: (Bool, String?) -> Void = { _, _ in }
    var quotaResetDisplayMode = QuotaResetDisplayMode.countdown
    var onQuotaResetDisplayModeChanged: (QuotaResetDisplayMode) -> Void = { _ in }
    /// Draws one window's reset label as though the pointer were on it. Only the frame dump sets
    /// it: off screen there is no pointer, and the lift on hover is the whole of what tells a
    /// reader the label is a switch.
    var hoveredResetLabelWindow: QuotaWindowKind?
    var onRefresh: (Provider) -> Void = { _ in }
    var onOpenPricing: () -> Void = {}
    var onRefreshLocalUsage: (Provider) -> Void = { _ in }

    /// The widest reset label across every provider, so all quota bars end at the same place.
    @State private var resetColumnWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Provider.allCases, id: \.self) { provider in
                ProviderSection(
                    provider: provider,
                    display: self.displays[provider] ?? ProviderDisplay(),
                    isRefreshing: self.refreshingProviders.contains(provider),
                    isExpanded: self.expandedProvider == provider,
                    animatesFill: self.animatesFill,
                    recoveries: self.recoveries[provider] ?? [:],
                    celebrationTokens: self.celebrationTokens[provider] ?? [:],
                    now: self.now,
                    resetDisplayMode: self.quotaResetDisplayMode,
                    hoveredResetLabelWindow: self.hoveredResetLabelWindow,
                    onToggle: { self.onProviderToggled(provider) },
                    onResetDisplayModeChanged: self.onQuotaResetDisplayModeChanged,
                    onRefresh: { self.onRefresh(provider) }
                )
            }
            .environment(\.resetColumnWidth, self.resetColumnWidth)
            // Local logs remain readable without the credentials required for quota and credits.
            if !self.costSnapshots.isEmpty || self.scanStatuses.contains(where: { $0.status != .idle }) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    self.localUsage
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ResetColumnWidthKey.self) { width in
            if abs(width - self.resetColumnWidth) > 0.5 { self.resetColumnWidth = width }
        }
    }

#if DEBUG
    func debugStatusLine(for provider: Provider) -> String {
        ProviderSection.statusLine(
            display: self.displays[provider] ?? ProviderDisplay(),
            isRefreshing: self.refreshingProviders.contains(provider),
            now: self.now
        )
    }
#endif

    private var costSnapshots: [CostSnapshot] {
        Provider.allCases.compactMap { self.displays[$0]?.cost }
    }

    private var scanStatuses: [(provider: Provider, status: LocalScanStatus)] {
        Provider.allCases.map { ($0, self.displays[$0]?.localScanStatus ?? .idle) }
    }

    @ViewBuilder
    private var localUsage: some View {
        if !self.costSnapshots.isEmpty {
            CostSectionView(
                snapshots: self.costSnapshots,
                labelMode: self.costChartLabelMode,
                onLabelModeChanged: self.onCostChartLabelModeChanged,
                isBreakdownExpanded: self.isCostBreakdownExpanded,
                expandedBreakdownDayKey: self.expandedCostBreakdownDayKey,
                onBreakdownExpandedChanged: self.onCostBreakdownExpandedChanged,
                onOpenPricing: self.onOpenPricing
            )
        } else {
            Text("Local usage").font(.system(size: 13, weight: .semibold))
        }
        ForEach(self.scanStatuses, id: \.provider) { entry in
            self.scanStatus(entry.provider, entry.status)
        }
    }

    @ViewBuilder
    private func scanStatus(_ provider: Provider, _ status: LocalScanStatus) -> some View {
        let hasCost = self.displays[provider]?.cost != nil
        switch status {
        case .idle, .completed:
            EmptyView()
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(hasCost
                    ? "Updating \(provider.displayName) usage…"
                    : "Scanning \(provider.displayName) usage…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(provider.displayName): \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry \(provider.displayName) scan") { self.onRefreshLocalUsage(provider) }
                    .buttonStyle(.link)
            }
            .font(.system(size: 11))
        }
    }
}

/// Each row reports its reset label width; the card keeps the widest.
private struct ResetColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ResetColumnWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var resetColumnWidth: CGFloat {
        get { self[ResetColumnWidthEnvironmentKey.self] }
        set { self[ResetColumnWidthEnvironmentKey.self] = newValue }
    }
}

/// One provider's quota windows in a compact grid, with a header that opens its detail: the
/// refresh warning, the pace behind each window, or the full sign-in guide.
private struct ProviderSection: View {
    @Environment(\.providerRefreshStates) private var refreshStates
    @Environment(\.resetColumnWidth) private var resetColumnWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedCommand = false
    /// Where each window's bar publishes its reset frame, so the reading beside it can follow.
    @StateObject private var sessionCelebration = QuotaCelebrationRelay()
    @StateObject private var weeklyCelebration = QuotaCelebrationRelay()

    let provider: Provider
    let display: ProviderDisplay
    let isRefreshing: Bool
    let isExpanded: Bool
    let animatesFill: Bool
    let recoveries: [QuotaWindowKind: QuotaRecoveryEvent]
    let celebrationTokens: [QuotaWindowKind: Int]
    let now: Date
    let resetDisplayMode: QuotaResetDisplayMode
    let hoveredResetLabelWindow: QuotaWindowKind?
    let onToggle: () -> Void
    let onResetDisplayModeChanged: (QuotaResetDisplayMode) -> Void
    let onRefresh: () -> Void

    private var tint: Color { Theme.accent(for: self.provider) }

    private var refreshState: RefreshRowPolicy.State {
        self.refreshStates[self.provider]
            ?? RefreshRowPolicy.State(title: RefreshRowPolicy.idleTitle, trailingText: nil, isEnabled: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.header
            if self.display.isSignedOut {
                if self.isExpanded { self.signInGuide } else { self.signInLine }
            } else if let snapshot = self.display.snapshot {
                self.windows(snapshot)
                if self.isExpanded { self.details(snapshot) }
            } else if let error = self.display.error {
                // Nothing else to show, so the warning stays in view even while collapsed.
                self.refreshWarning(error)
            }
        }
        .task(id: self.copiedCommand) {
            guard self.copiedCommand else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.copiedCommand = false
        }
    }

    // MARK: - Header

    private var header: some View {
        Button(action: self.onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(self.tint)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(self.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if self.display.error != nil, !self.display.isSignedOut {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Refresh failed")
                }
                Spacer(minLength: 8)
                Text(self.headerStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DisclosureChevron(isOpen: self.isExpanded, reduceMotion: self.reduceMotion)
                    .frame(width: 10, height: 12)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle())
        .keyboardShortcut(self.provider == .codex ? "1" : "2", modifiers: .command)
        .accessibilityLabel("\(self.provider.displayName) details")
        .accessibilityValue(self.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(self.isExpanded ? "Collapse details" : "Expand details")
    }

    /// Short enough to share the header with the provider's name.
    private var headerStatus: String {
        if self.display.isSignedOut { return "Not signed in" }
        if let snapshot = self.display.snapshot {
            let age = Formatters.relativeAge(since: snapshot.fetchedAt, now: self.now)
            if self.display.error != nil { return "Saved \(age)" }
            if self.isRefreshing { return "Refreshing…" }
            return [snapshot.planLabel, age].compactMap { $0 }.joined(separator: " · ")
        }
        if self.isRefreshing { return "Refreshing…" }
        return self.display.error == nil ? "No data yet" : "Refresh failed"
    }

    static func statusLine(display: ProviderDisplay, isRefreshing: Bool, now: Date) -> String {
        if display.isSignedOut { return "Not signed in" }
        if display.error != nil, let snapshot = display.snapshot {
            return "Last successful update · \(Formatters.relativeAge(since: snapshot.fetchedAt, now: now))"
        }
        if isRefreshing { return "Refreshing…" }
        guard let snapshot = display.snapshot else {
            return display.error == nil ? "No data yet" : "Refresh failed"
        }
        return "Updated \(Formatters.relativeAge(since: snapshot.fetchedAt, now: now))"
    }

    // MARK: - Windows

    @ViewBuilder
    private func windows(_ snapshot: UsageSnapshot) -> some View {
        let credits = snapshot.credits.flatMap { $0.hasSpendableBalance ? $0 : nil }
        if snapshot.session == nil, snapshot.weekly == nil, !snapshot.sessionIsUnlimited, credits == nil {
            Text("No quota windows reported.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                if let session = snapshot.session {
                    self.windowRow(session, kind: .session)
                } else if snapshot.sessionIsUnlimited {
                    // Held in the session slot rather than dropped, so a plan without the
                    // five-hour cap lines up with one that has it.
                    self.row(
                        title: QuotaWindowKind.session.presentation.title,
                        bar: UsageProgressBar(percent: 100, tint: self.tint.opacity(0.35), animatesFill: false),
                        value: Text("∞").foregroundStyle(.primary),
                        trailing: Text("No limit").foregroundStyle(.secondary)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Session has no limit")
                }
                if let weekly = snapshot.weekly {
                    self.windowRow(weekly, kind: .weekly)
                }
                if let credits {
                    self.row(
                        title: "Credits",
                        bar: UsageProgressBar(
                            percent: credits.unlimited ? 100 : min(100, (credits.balance ?? 0) / 10),
                            tint: self.tint,
                            animatesFill: self.animatesFill
                        ),
                        value: Text(credits.unlimited ? "∞" : "\(Int((credits.balance ?? 0).rounded()))")
                            .foregroundStyle(.primary),
                        trailing: Text(credits.unlimited ? "Unlimited" : "of 1K").foregroundStyle(.secondary)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(credits.unlimited
                        ? "Credits unlimited"
                        : "Credits \(Int((credits.balance ?? 0).rounded())) of 1,000 left")
                }
            }
        }
    }

    private func windowRow(_ window: UsageWindow, kind: QuotaWindowKind) -> some View {
        let pace = self.pace(for: window, kind: kind)
        let isExhausted = window.remainingPercent <= 0
        let summary = isExhausted ? "Limit reached"
            : pace.map { Self.paceSummary(for: $0, context: kind.presentation.paceContext) }
        let color: Color = isExhausted ? .red : pace?.stage.isAhead == true ? .orange : .primary
        let relay = kind == .session ? self.sessionCelebration : self.weeklyCelebration
        return self.row(
            title: kind.presentation.title,
            bar: UsageProgressBar(
                percent: window.remainingPercent,
                tint: self.tint,
                animatesFill: self.animatesFill,
                celebrationToken: self.recoveries[kind] == nil ? 0 : self.celebrationTokens[kind] ?? 0,
                celebrationStartPercent: self.recoveries[kind]?.fromRemainingPercent,
                allowsCelebrationReplay: true,
                celebrationRelay: relay
            ),
            value: RelayedQuotaPercentLabel(
                percent: window.remainingPercent,
                color: color,
                tint: self.tint,
                relay: relay
            ),
            trailing: window.resetsAt.map { resetsAt in
                ResetLabel(
                    text: QuotaResetLabel.text(resetsAt: resetsAt, mode: self.resetDisplayMode, now: self.now),
                    mode: self.resetDisplayMode,
                    previewHovered: kind == self.hoveredResetLabelWindow,
                    showsSymbol: false,
                    onModeChanged: self.onResetDisplayModeChanged
                )
            }
        )
        .help(summary ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.presentation.title) \(Formatters.percent(window.remainingPercent)) left"
            + (summary.map { ", \($0)" } ?? ""))
    }

    /// Label, bar, reading, and reset: the same four columns for every row, so bars line up.
    private func row(
        title: String,
        bar: some View,
        value: some View,
        trailing: (some View)?
    ) -> some View {
        GridRow(alignment: .center) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            bar
                .frame(minWidth: 40)
            value
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 30, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Group {
                if let trailing { trailing } else { Color.clear.frame(width: 0, height: 0) }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .background {
                GeometryReader { Color.clear.preference(key: ResetColumnWidthKey.self, value: $0.size.width) }
            }
            .frame(minWidth: self.resetColumnWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func details(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = self.display.error {
                self.refreshWarning(error)
            } else {
                Text(Self.statusLine(display: self.display, isRefreshing: self.isRefreshing, now: self.now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach([QuotaWindowKind.session, .weekly], id: \.self) { kind in
                if let window = kind == .session ? snapshot.session : snapshot.weekly,
                   let pace = self.pace(for: window, kind: kind) {
                    self.paceDetail(window: window, pace: pace, kind: kind)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.top, 2)
    }

    private func pace(for window: UsageWindow, kind: QuotaWindowKind) -> UsagePace? {
        let context = kind.presentation.paceContext
        return (kind == .weekly
            ? HistoricalUsagePace.evaluate(window: window, dataset: self.display.history, now: self.now)
            : nil)
            ?? UsagePace.evaluate(window: window, context: context, now: self.now)
    }

    private static func paceSummary(for pace: UsagePace, context: UsagePace.Context) -> String {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let eta = pace.etaLabel(context: context, durationText: Formatters.compactDuration) else {
            return pace.deltaLabel
        }
        return (eta.components(separatedBy: " (").first ?? eta)
            .replacingOccurrences(of: "Projected empty in ", with: "Empty in about ")
    }

    private func paceDetail(window: UsageWindow, pace: UsagePace, kind: QuotaWindowKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(kind.presentation.title) · \(Self.paceSummary(for: pace, context: kind.presentation.paceContext))")
                .fontWeight(.medium)
                .foregroundStyle(pace.stage.isAhead ? Color.orange : Color.primary)
            Text(pace.deltaLabel)
            Text("Expected \(Formatters.percent(pace.expectedRemainingPercent)) left now")
            if let multiplier = pace.speedMultiplierToReset {
                Text(String(format: "%.1f× headroom at current pace", multiplier))
            }
            UsageProgressBar(
                percent: window.remainingPercent,
                tint: self.tint,
                pacePercent: pace.expectedRemainingPercent,
                paceIsDeficit: pace.stage.isAhead,
                animatesFill: false
            )
            .accessibilityLabel("\(kind.presentation.title) pace: \(pace.deltaLabel)")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshWarning(_ error: String) -> some View {
        let denied = self.display.failure?.kind == .accessDenied
        return VStack(alignment: .leading, spacing: 5) {
            Label(
                denied ? "Keychain not read"
                    : self.display.snapshot == nil ? "Refresh failed" : "Refresh failed · Showing saved reading",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            Text(denied
                ? "\(error) \(self.provider.displayName) is not checked automatically until you ask again."
                : error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if self.isRefreshing {
                Label("Refreshing…", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            } else if self.refreshState.isEnabled {
                Button(self.display.canAttemptCredentialRecovery
                    ? "Recover with Claude Code" : denied ? "Ask again" : "Try again") {
                    self.onRefresh()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.link)
            } else if let remaining = self.refreshState.trailingText {
                Text("Try again in \(remaining)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sign-in

    private var signInCommand: String {
        switch self.provider {
        case .codex: "codex login"
        case .claude: "claude"
        }
    }

    private var copyButton: some View {
        Button(self.copiedCommand ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.signInCommand, forType: .string)
            self.copiedCommand = true
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .accessibilityLabel("Copy \(self.signInCommand) command")
    }

    /// The whole signed-out state while collapsed: the command that fixes it, ready to copy.
    private var signInLine: some View {
        HStack(spacing: 8) {
            Text(self.signInCommand)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            self.copyButton
        }
    }

    private var signInGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use the \(self.provider.displayName) CLI in Terminal to sign in, then return here to check.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(self.signInCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                self.copyButton
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            Button(action: self.onRefresh) {
                HStack(spacing: 6) {
                    if self.isRefreshing { ProgressView().controlSize(.small) }
                    Text(self.isRefreshing ? "Checking…" : "Check sign-in")
                    if let remaining = self.refreshState.trailingText, !self.isRefreshing {
                        Spacer(minLength: 4)
                        Text(remaining).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!self.refreshState.isEnabled)
            .buttonStyle(.borderedProminent)
            if let reason = self.display.signedOutReason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension QuotaWindowKind {
    var presentation: (title: String, paceContext: UsagePace.Context) {
        switch self {
        case .session: ("Session", .session)
        case .weekly: ("Weekly", .weekly)
        }
    }
}
