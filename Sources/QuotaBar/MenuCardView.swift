import QuotaBarCore
import AppKit
import SwiftUI

/// The 280 pt provider card hosted inside the status item's popover.
struct MenuCardView: View {
    @Environment(\.menuRefreshState) private var refreshState
    @State private var copiedCommand = false
    @State private var showsPaceDetails = false

    let provider: Provider
    let display: ProviderDisplay
    let isRefreshing: Bool
    /// False for the offscreen card dump, which captures a stable frame without transitions.
    var animatesFill = true
    /// Windows that reset and the final remaining percentage observed before each reset.
    var recoveries: [QuotaWindowKind: QuotaRecoveryEvent] = [:]
    /// Bumped per window, so one reset cannot replay the other window's finished animation.
    var celebrationTokens: [QuotaWindowKind: Int] = [:]
    /// Captured when the card is rebuilt so relative labels can be tested without wall-clock waits.
    var now = Date()
    var costChartLabelMode = CostChartLabelMode.tokens
    var onCostChartLabelModeChanged: (CostChartLabelMode) -> Void = { _ in }
    /// Whether the cost breakdown is showing every model of the selected day. It is held by the
    /// menu rather than by the card, because opening the list is the one click that changes the
    /// card's height and the hosting view has to be resized around it.
    var isCostBreakdownExpanded = false
    /// How far open the list is drawn right now. Nil follows the flag above, which is every card
    /// that is not mid-sweep.
    var costBreakdownOpenness: Double?
    /// The day being held open, shared with the controller's off-screen height probe.
    var expandedCostBreakdownDayKey: String?
    var onCostBreakdownExpandedChanged: (Bool, String?) -> Void = { _, _ in }
    var quotaResetDisplayMode = QuotaResetDisplayMode.countdown
    var onQuotaResetDisplayModeChanged: (QuotaResetDisplayMode) -> Void = { _ in }
    /// Draws one window's reset label as though the pointer were on it. Only the frame dump sets
    /// it: off screen there is no pointer, and the lift on hover is the whole of what tells a
    /// reader the label is a switch.
    var hoveredResetLabelWindow: QuotaWindowKind?
    var onProviderSelected: (Provider) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onOpenPricing: () -> Void = {}
    var onRefreshLocalUsage: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            if !self.display.isSignedOut, let error = self.display.error {
                self.refreshWarning(error)
                    .padding(.top, 9)
            }
            Divider().padding(.vertical, 8)
            self.content
                .id(self.provider)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onChange(of: self.provider) { _, _ in
            self.copiedCommand = false
            self.showsPaceDetails = false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The switch names the provider, so the card needs no title of its own.
            ProviderTabBar(
                selection: self.provider,
                onSelect: self.onProviderSelected
            )
            HStack(spacing: 0) {
                Text(self.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let plan = self.planLabel {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusLine: String {
        if self.display.isSignedOut { return "Not signed in" }
        if self.display.error != nil, let snapshot = self.display.snapshot {
            return "Last successful update · \(Formatters.relativeAge(since: snapshot.fetchedAt, now: self.now))"
        }
        if self.isRefreshing { return "Refreshing…" }
        guard let snapshot = self.display.snapshot else {
            return self.display.error == nil ? "No data yet" : "Refresh failed"
        }
        return "Updated \(Formatters.relativeAge(since: snapshot.fetchedAt, now: self.now))"
    }

#if DEBUG
    var debugStatusLine: String { self.statusLine }
#endif

    private var planLabel: String? {
        self.display.snapshot?.planLabel
    }

    private static func paceSummary(for pace: UsagePace, context: UsagePace.Context) -> String {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let eta = pace.etaLabel(context: context, durationText: Formatters.compactDuration) else {
            return pace.deltaLabel
        }
        return (eta.components(separatedBy: " (").first ?? eta)
            .replacingOccurrences(of: "Projected empty in ", with: "Empty in about ")
    }

    // MARK: - Body

    private func refreshWarning(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                self.display.snapshot == nil ? "Refresh failed" : "Refresh failed · Showing saved data",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if self.isRefreshing {
                Label("Refreshing…", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            } else if self.refreshState.isEnabled {
                Button(self.display.canAttemptCredentialRecovery ? "Recover with Claude Code" : "Try again") {
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

    private var signInCommand: String {
        switch self.provider {
        case .codex: "codex login"
        case .claude: "claude"
        }
    }

    private var signInGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to \(self.provider.displayName)")
                .font(.system(size: 14, weight: .semibold))
            Text("Use the \(self.provider.displayName) CLI in Terminal to sign in, then return here to check.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(self.signInCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(self.copiedCommand ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.signInCommand, forType: .string)
                    self.copiedCommand = true
                }
                .font(.system(size: 11))
                .accessibilityLabel("Copy \(self.signInCommand) command")
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
        .task(id: self.copiedCommand) {
            guard self.copiedCommand else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.copiedCommand = false
        }
    }

    @ViewBuilder
    private var localUsage: some View {
        if let cost = self.display.cost {
            CostSectionView(
                snapshot: cost,
                labelMode: self.costChartLabelMode,
                onLabelModeChanged: self.onCostChartLabelModeChanged,
                isBreakdownExpanded: self.isCostBreakdownExpanded,
                breakdownOpenness: self.costBreakdownOpenness,
                expandedBreakdownDayKey: self.expandedCostBreakdownDayKey,
                onBreakdownExpandedChanged: self.onCostBreakdownExpandedChanged,
                onOpenPricing: self.onOpenPricing
            )
        }
        switch self.display.localScanStatus {
        case .idle:
            if self.display.cost == nil {
                Text("Local usage has not loaded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(self.display.cost == nil ? "Scanning local usage…" : "Updating local usage…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .completed:
            EmptyView()
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry local scan", action: self.onRefreshLocalUsage)
                    .buttonStyle(.link)
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.display.isSignedOut {
                self.signInGuide
            } else {
                if let snapshot = self.display.snapshot {
                if let session = snapshot.session {
                    self.window(window: session, kind: .session)
                } else if snapshot.sessionIsUnlimited {
                    // Held in the session slot rather than dropped, so a plan without the
                    // five-hour cap lines up with one that has it.
                    UnlimitedWindowRow(
                        title: QuotaWindowKind.session.presentation.title,
                        tint: Theme.accent(for: self.provider)
                    )
                }
                if let weekly = snapshot.weekly {
                    self.window(window: weekly, kind: .weekly)
                }
                if snapshot.session == nil, snapshot.weekly == nil, !snapshot.sessionIsUnlimited {
                    Text("No quota windows reported.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if snapshot.session != nil || snapshot.weekly != nil {
                    self.paceDetails(for: snapshot)
                }
                }
                if self.display.cost != nil || self.display.localScanStatus != .idle {
                    if self.display.snapshot != nil { Divider().padding(.top, 2) }
                    self.localUsage
                }
                if let credits = self.display.snapshot?.credits, credits.hasSpendableBalance {
                    Divider().padding(.top, 2)
                    CreditsSectionView(credits: credits)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func window(
        window: UsageWindow,
        kind: QuotaWindowKind
    ) -> some View {
        let presentation = kind.presentation
        let pace = self.pace(for: window, kind: kind)
        return QuotaWindowRow(
            provider: self.provider,
            title: presentation.title,
            window: window,
            paceSummary: pace.map { Self.paceSummary(for: $0, context: presentation.paceContext) },
            paceIsDeficit: pace?.stage.isAhead == true,
            animatesFill: self.animatesFill,
            celebrationToken: self.recoveries[kind] == nil ? 0 : self.celebrationTokens[kind] ?? 0,
            celebrationStartPercent: self.recoveries[kind]?.fromRemainingPercent,
            now: self.now,
            resetDisplayMode: self.quotaResetDisplayMode,
            isResetLabelHovered: kind == self.hoveredResetLabelWindow,
            onResetDisplayModeChanged: self.onQuotaResetDisplayModeChanged
        )
    }

    private func pace(for window: UsageWindow, kind: QuotaWindowKind) -> UsagePace? {
        let context = kind.presentation.paceContext
        return (kind == .weekly
            ? HistoricalUsagePace.evaluate(window: window, dataset: self.display.history, now: self.now)
            : nil)
            ?? UsagePace.evaluate(window: window, context: context, now: self.now)
    }

    @ViewBuilder
    private func paceDetails(for snapshot: UsageSnapshot) -> some View {
        let sessionPace = snapshot.session.flatMap { self.pace(for: $0, kind: .session) }
        let weeklyPace = snapshot.weekly.flatMap { self.pace(for: $0, kind: .weekly) }
        if sessionPace != nil || weeklyPace != nil {
            DisclosureGroup("Usage pace details", isExpanded: self.$showsPaceDetails) {
                VStack(alignment: .leading, spacing: 9) {
                    if let session = snapshot.session, let sessionPace {
                        self.paceDetail(window: session, pace: sessionPace, kind: .session)
                    }
                    if let weekly = snapshot.weekly, let weeklyPace {
                        self.paceDetail(window: weekly, pace: weeklyPace, kind: .weekly)
                    }
                }
                .padding(.top, 5)
            }
            .font(.system(size: 11))
            .disclosureGroupStyle(PopoverDisclosureStyle())
        }
    }

    private func paceDetail(window: UsageWindow, pace: UsagePace, kind: QuotaWindowKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(kind.presentation.title) · \(pace.deltaLabel)")
                .fontWeight(.medium)
            if let eta = pace.etaLabel(
                context: kind.presentation.paceContext,
                durationText: Formatters.compactDuration
            ) {
                Text(eta.components(separatedBy: " · ").first ?? eta)
            }
            Text("Expected \(Formatters.percent(pace.expectedRemainingPercent)) left now")
            if let multiplier = pace.speedMultiplierToReset {
                Text(String(format: "%.1f× headroom at current pace", multiplier))
            }
            UsageProgressBar(
                percent: window.remainingPercent,
                tint: Theme.accent(for: self.provider),
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
}

private extension QuotaWindowKind {
    var presentation: (title: String, paceContext: UsagePace.Context) {
        switch self {
        case .session: ("Session", .session)
        case .weekly: ("Weekly", .weekly)
        }
    }
}

/// One quota window with its authoritative reading above the bar and its reset control below.
private struct QuotaWindowRow: View {
    let provider: Provider
    let title: String
    let window: UsageWindow
    let paceSummary: String?
    let paceIsDeficit: Bool
    let animatesFill: Bool
    let celebrationToken: Int
    let celebrationStartPercent: Double?
    /// Passed in rather than read here so the reset label renders the same on the offscreen dump
    /// and in the verifiers as it does against the wall clock.
    let now: Date
    let resetDisplayMode: QuotaResetDisplayMode
    let isResetLabelHovered: Bool
    let onResetDisplayModeChanged: (QuotaResetDisplayMode) -> Void

    @StateObject private var celebration = QuotaCelebrationRelay()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuotaHeadline(
                title: self.title,
                percent: self.window.remainingPercent,
                tint: Theme.accent(for: self.provider),
                frame: self.celebration.frame
            )
#if DEBUG
            .background {
                QuotaLayoutProbe(identifier: "headline")
            }
#endif
            UsageProgressBar(
                percent: self.window.remainingPercent,
                tint: Theme.accent(for: self.provider),
                animatesFill: self.animatesFill,
                celebrationToken: self.celebrationToken,
                celebrationStartPercent: self.celebrationStartPercent,
                allowsCelebrationReplay: true,
                celebrationRelay: self.celebration
            )
            if self.paceSummary != nil || self.window.resetsAt != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        self.paceSummaryLabel
                        Spacer(minLength: 0)
                        self.resetMenu
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        self.paceSummaryLabel
                        self.resetMenu
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var paceSummaryLabel: some View {
        if let paceSummary = self.paceSummary {
            Text(paceSummary)
                .font(.system(size: 11))
                .foregroundStyle(self.paceIsDeficit ? Color.orange : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var resetMenu: some View {
        if let resetsAt = self.window.resetsAt {
            ResetLabel(
                text: QuotaResetLabel.text(
                    resetsAt: resetsAt,
                    mode: self.resetDisplayMode,
                    now: self.now
                ),
                mode: self.resetDisplayMode,
                previewHovered: self.isResetLabelHovered,
                onModeChanged: self.onResetDisplayModeChanged
            )
        }
    }
}

/// A window the plan does not cap: the same headline, bar and trailing label as a metered row, so
/// the card keeps its shape, but nothing on it counts down. The bar sits full and faded, since
/// there is no balance for it to spend and a full-strength fill would read as a fresh reset.
private struct UnlimitedWindowRow: View {
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(self.title) ∞")
                    .font(QuotaHeadline.font)
                Spacer(minLength: 0)
                Text("No limit")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            UsageProgressBar(percent: 100, tint: self.tint.opacity(0.35), animatesFill: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.title) has no limit")
    }
}

#if DEBUG
/// A zero-drawing AppKit view that records the frame SwiftUI assigned to one card label. It is
/// present only in debug builds so the layout verifier can inspect the real hosting hierarchy.
final class QuotaLayoutProbeView: NSView {
    let probeIdentifier: String

    init(identifier: String) {
        self.probeIdentifier = identifier
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct QuotaLayoutProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> QuotaLayoutProbeView {
        QuotaLayoutProbeView(identifier: self.identifier)
    }

    func updateNSView(_ nsView: QuotaLayoutProbeView, context: Context) {}
}
#endif
