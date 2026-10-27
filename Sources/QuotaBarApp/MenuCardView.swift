import QuotaBarCore
import AppKit
import SwiftUI

/// The 280 pt provider card hosted inside the status item's popover.
struct MenuCardView: View {
    @Environment(\.menuRefreshState) private var refreshState
    @State private var copiedCommand = false
    /// What this card last drew. Read while the next state is being drawn, so the content that
    /// arrives knows whether it replaced something in an open card or opened with the card.
    @State private var shownProvider: Provider?
    @State private var shownSignedOut: Bool?
    @State private var shownSkeleton = false
    /// A sign-in check just succeeded: the status line confirms it for a moment.
    @State private var confirmsSignIn = false

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
    /// The day being held open, shared with the controller's off-screen height probe.
    var expandedCostBreakdownDayKey: String?
    var onCostBreakdownExpandedChanged: (Bool, String?) -> Void = { _, _ in }
    var quotaResetDisplayMode = QuotaResetDisplayMode.countdown
    var onQuotaResetDisplayModeChanged: (QuotaResetDisplayMode) -> Void = { _ in }
    var onProviderSelected: (Provider) -> Void = { _ in }
    var onRefresh: () -> Void = {}
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
                // Only a switch inside an open card slides; opening the card never does.
                .transition(self.switchedProvider
                    ? .providerSlide(fromTrailing: self.providerIndex > 0)
                    : .identity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .environment(\.cardMotionEnabled, self.animatesFill)
        .onAppear {
            self.shownProvider = self.provider
            self.shownSignedOut = self.display.isSignedOut
        }
        .onChange(of: self.provider) { _, provider in
            self.shownProvider = provider
            self.shownSignedOut = self.display.isSignedOut
            self.copiedCommand = false
            self.confirmsSignIn = false
        }
        .onChange(of: self.display.isSignedOut) { wasSignedOut, isSignedOut in
            self.shownSignedOut = isSignedOut
            self.confirmsSignIn = wasSignedOut && !isSignedOut
        }
        .task(id: self.confirmsSignIn) {
            guard self.confirmsSignIn else { return }
            try? await Task.sleep(for: .seconds(CardMotion.confirmationHold))
            guard !Task.isCancelled else { return }
            self.confirmsSignIn = false
        }
    }

    private var providerIndex: Int {
        Provider.allCases.firstIndex(of: self.provider) ?? 0
    }

    private var switchedProvider: Bool {
        self.shownProvider != nil && self.shownProvider != self.provider
    }

    /// Quota replacing the sign-in guide in an open card, rather than quota the card opened with.
    private var arrivedFromSignIn: Bool {
        self.shownSignedOut == true && !self.display.isSignedOut && !self.switchedProvider
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
                if self.confirmsSignIn {
                    HStack(spacing: 5) {
                        ResolveCheck(tint: Theme.accent(for: self.provider))
                        Text("Signed in")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text(self.statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
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
                Label {
                    WorkingLabel(title: "Refreshing…")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
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
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.signInCommand, forType: .string)
                    self.copiedCommand = true
                } label: {
                    if self.copiedCommand {
                        HStack(spacing: 4) {
                            ResolveCheck(tint: Theme.accent(for: self.provider), size: 10)
                            Text("Copied")
                        }
                    } else {
                        Text("Copy command")
                    }
                }
                .font(.system(size: 11))
                .accessibilityLabel("Copy \(self.signInCommand) command")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            Button(action: self.onRefresh) {
                HStack(spacing: 6) {
                    if self.isRefreshing {
                        WorkingLabel(title: "Checking…")
                    } else {
                        Text("Check sign-in")
                    }
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
            try? await Task.sleep(for: .seconds(CardMotion.confirmationHold))
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
                expandedBreakdownDayKey: self.expandedCostBreakdownDayKey,
                onBreakdownExpandedChanged: self.onCostBreakdownExpandedChanged
            )
            // Fades in only when it replaces the placeholder, not when the card opens with it.
            .placeholderReveal(active: self.shownSkeleton)
        }
        switch self.display.localScanStatus {
        case .idle:
            if self.display.cost == nil {
                Text("Local usage has not loaded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .scanning:
            if self.display.cost == nil {
                LocalUsageSkeleton()
                    .onAppear { self.shownSkeleton = true }
            } else {
                WorkingLabel(title: "Updating local usage…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
            } else if let snapshot = self.display.snapshot {
                self.quota(snapshot)
                    .cardReveal(active: self.arrivedFromSignIn)
            }
            // Local logs remain readable without the credentials required for quota and credits.
            if self.display.cost != nil || self.display.localScanStatus != .idle {
                if self.display.isSignedOut || self.display.snapshot != nil {
                    Divider().padding(.top, 2)
                }
                self.localUsage
            }
            if !self.display.isSignedOut,
               let credits = self.display.snapshot?.credits, credits.hasSpendableBalance {
                Divider().padding(.top, 2)
                CreditsSectionView(credits: credits)
            }
        }
        .padding(.bottom, 6)
    }

    /// The quota windows, in one stack so they can arrive together after a sign-in.
    private func quota(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = snapshot.session {
                self.window(window: session, kind: .session)
            } else if snapshot.sessionIsUnlimited {
                // Held in the session slot rather than dropped, so a plan without the
                // five-hour cap lines up with one that has it.
                UnlimitedWindowRow(
                    title: QuotaWindowKind.session.title,
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
        }
    }

    private func window(
        window: UsageWindow,
        kind: QuotaWindowKind
    ) -> some View {
        let pace = self.display.pace.pace(for: kind, window: window, now: self.now)
        return QuotaWindowRow(
            provider: self.provider,
            title: kind.title,
            window: window,
            paceSummary: pace?.summary(kind: kind, durationText: Formatters.compactDuration),
            pacePercent: pace?.expectedRemainingPercent,
            paceIsDeficit: pace?.stage.isAhead == true,
            animatesFill: self.animatesFill,
            celebrationToken: self.recoveries[kind] == nil ? 0 : self.celebrationTokens[kind] ?? 0,
            celebrationStartPercent: self.recoveries[kind]?.fromRemainingPercent,
            now: self.now,
            resetDisplayMode: self.quotaResetDisplayMode,
            onResetDisplayModeChanged: self.onQuotaResetDisplayModeChanged
        )
    }
}

private extension QuotaWindowKind {
    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

/// One quota window with its authoritative reading above the bar and its reset control below.
private struct QuotaWindowRow: View {
    let provider: Provider
    let title: String
    let window: UsageWindow
    let paceSummary: String?
    /// Where the fill would sit at an even pace, drawn as a marker on the bar.
    let pacePercent: Double?
    let paceIsDeficit: Bool
    let animatesFill: Bool
    let celebrationToken: Int
    let celebrationStartPercent: Double?
    /// Passed in rather than read here so the reset label renders the same on the offscreen dump
    /// and in the verifiers as it does against the wall clock.
    let now: Date
    let resetDisplayMode: QuotaResetDisplayMode
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
            UsageProgressBar(
                percent: self.window.remainingPercent,
                tint: Theme.accent(for: self.provider),
                pacePercent: self.pacePercent,
                paceIsDeficit: self.paceIsDeficit,
                animatesFill: self.animatesFill,
                celebrationToken: self.celebrationToken,
                celebrationStartPercent: self.celebrationStartPercent,
                allowsCelebrationReplay: true,
                celebrationRelay: self.celebration
            )
            if self.paceSummary != nil || self.isExhausted || self.window.resetsAt != nil {
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

    /// No pace is derived for an empty window, so the status takes the pace line's place instead
    /// of leaving it blank beside the reset label.
    private var isExhausted: Bool {
        self.window.remainingPercent <= 0
    }

    @ViewBuilder
    private var paceSummaryLabel: some View {
        if self.isExhausted {
            Text("Limit reached")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else if let paceSummary = self.paceSummary {
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
