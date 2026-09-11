import QuotaBarCore
import AppKit
import SwiftUI

/// The custom card hosted inside the status item's menu — the top half of CodexBar's popover.
/// M1 renders the header and the two quota windows; cost, tokens and the chart arrive in M2.
struct MenuCardView: View {
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
    /// What each provider's tightest window has left, for the switch at the top of the card.
    var providerRemaining: [Provider: Double] = [:]
    var onProviderSelected: (Provider) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().padding(.vertical, 8)
            self.content
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(width: 280, alignment: .leading)
        // The card is laid out at the height its own contents want, and hangs from the top of
        // whatever the hosting view is currently sized to. Opening the breakdown sweeps that size
        // over a third of a second, and without this every step of the sweep would re-propose a
        // height to the whole card -- the chart and the lines above it would shuffle their way
        // through an animation that is happening underneath them.
        .fixedSize(horizontal: false, vertical: true)
        // `minHeight` is what makes this frame take the height it is offered rather than the one
        // the card wants: without it the frame reports the card's own height, the hosting view
        // finds a root taller than its bounds, and centres it -- so a sweep slides the whole card
        // up and back down through the animation.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The switch names the provider, so the card needs no title of its own.
            ProviderTabBar(
                selection: self.provider,
                remaining: self.providerRemaining,
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
        if self.isRefreshing { return "Refreshing…" }
        if self.display.isSignedOut { return "Not signed in" }
        guard let snapshot = self.display.snapshot else {
            return self.display.error == nil ? "No data yet" : "Refresh failed"
        }
        // Even after a failed refresh the age of the data on screen is what matters.
        return "Updated \(Formatters.relativeAge(since: snapshot.fetchedAt, now: self.now))"
    }

#if DEBUG
    var debugStatusLine: String { self.statusLine }
#endif

    private var planLabel: String? {
        self.display.snapshot?.planLabel
    }

    private static func paceLine(for pace: UsagePace, context: UsagePace.Context) -> String {
        guard let eta = pace.etaLabel(context: context, durationText: Formatters.compactDuration) else {
            return pace.deltaLabel
        }
        return "\(pace.deltaLabel) · \(eta)"
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                if snapshot.session == nil, snapshot.weekly == nil {
                    Text("No quota windows reported.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let cost = self.display.cost {
                    CostSectionView(
                        snapshot: cost,
                        labelMode: self.costChartLabelMode,
                        onLabelModeChanged: self.onCostChartLabelModeChanged,
                        isBreakdownExpanded: self.isCostBreakdownExpanded,
                        breakdownOpenness: self.costBreakdownOpenness,
                        expandedBreakdownDayKey: self.expandedCostBreakdownDayKey,
                        onBreakdownExpandedChanged: self.onCostBreakdownExpandedChanged
                    )
                }

                // Only Codex reports credits at all, and the section is only worth the space
                // when there is a balance left: with no credits the bar would sit empty at
                // "0 left", which tells the user nothing their quota windows do not.
                if let credits = snapshot.credits, credits.hasSpendableBalance {
                    Divider().padding(.top, 2)
                    CreditsSectionView(credits: credits)
                }
            }

            // The error is appended, never a replacement: a rate-limited refresh should not blank
            // out numbers that were correct a minute ago.
            if let error = self.display.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
    }

    private func window(
        window: UsageWindow,
        kind: QuotaWindowKind
    ) -> some View {
        let presentation = kind.presentation
        // Past weeks describe the real shape of usage better than the clock does, but only once
        // enough of them are on record; until then this falls back to the linear model.
        let pace = (presentation.paceContext == .weekly
            ? HistoricalUsagePace.evaluate(window: window, dataset: self.display.history)
            : nil)
            ?? UsagePace.evaluate(window: window, context: presentation.paceContext)
        return QuotaWindowRow(
            provider: self.provider,
            title: presentation.title,
            window: window,
            pace: pace,
            paceLine: pace.map { Self.paceLine(for: $0, context: presentation.paceContext) },
            animatesFill: self.animatesFill,
            celebrationToken: self.recoveries[kind] == nil ? 0 : self.celebrationTokens[kind] ?? 0,
            celebrationStartPercent: self.recoveries[kind]?.fromRemainingPercent,
            now: self.now,
            resetDisplayMode: self.quotaResetDisplayMode,
            isResetLabelHovered: kind == self.hoveredResetLabelWindow,
            onResetDisplayModeToggled: {
                self.onQuotaResetDisplayModeChanged(self.quotaResetDisplayMode.toggled)
            }
        )
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

/// One quota window: the headline, the bar, and the pace line. It is its own view so the headline
/// and the bar can share a reset — the bar owns the clock and publishes every frame into the relay
/// held here, which is also how the headline follows the hidden replay it knows nothing about.
private struct QuotaWindowRow: View {
    let provider: Provider
    let title: String
    let window: UsageWindow
    let pace: UsagePace?
    let paceLine: String?
    let animatesFill: Bool
    let celebrationToken: Int
    let celebrationStartPercent: Double?
    /// Passed in rather than read here so the reset label renders the same on the offscreen dump
    /// and in the verifiers as it does against the wall clock.
    let now: Date
    let resetDisplayMode: QuotaResetDisplayMode
    let isResetLabelHovered: Bool
    let onResetDisplayModeToggled: () -> Void

    @StateObject private var celebration = QuotaCelebrationRelay()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
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
                Spacer(minLength: 0)
                if let resetsAt = self.window.resetsAt {
                    ResetLabel(
                        text: QuotaResetLabel.text(
                            resetsAt: resetsAt,
                            mode: self.resetDisplayMode,
                            now: self.now
                        ),
                        previewHovered: self.isResetLabelHovered,
                        onToggle: self.onResetDisplayModeToggled
                    )
                }
            }
            UsageProgressBar(
                percent: self.window.remainingPercent,
                tint: Theme.accent(for: self.provider),
                // The bar shows what is left, so the pace tip marks the remaining side too.
                pacePercent: self.pace?.expectedRemainingPercent,
                paceIsDeficit: self.pace?.stage.isAhead ?? false,
                animatesFill: self.animatesFill,
                celebrationToken: self.celebrationToken,
                celebrationStartPercent: self.celebrationStartPercent,
                allowsCelebrationReplay: true,
                celebrationRelay: self.celebration
            )
            if let paceLine = self.paceLine {
                // One Text, not an HStack: split across views the line wraps mid-phrase.
                Text(paceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// The reset label doubles as its own switch: one click trades the countdown for the clock time
/// it is counting down to, and back. The click cannot come from `.onTapGesture` — an NSMenu popup
/// is never the key window, so SwiftUI's gestures never fire inside the card — so it arrives
/// through the same always-active tracking view the cost chart uses.
private struct ResetLabel: View {
    let text: String
    /// Held on by the frame dump, which has no pointer of its own.
    var previewHovered = false
    let onToggle: () -> Void

    @State private var isHovered = false

    private var showsHover: Bool { self.isHovered || self.previewHovered }

    var body: some View {
        Text(self.text)
            .font(.system(size: 11))
            // Nothing else on the card responds to the pointer this way, so the lift on hover is
            // what tells the reader the label is worth clicking at all.
            .foregroundStyle(self.showsHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .animation(.easeOut(duration: 0.12), value: self.showsHover)
            .overlay {
                MouseLocationReader(
                    onMoved: { location in
                        let hovered = location != nil
                        guard self.isHovered != hovered else { return }
                        self.isHovered = hovered
                    },
                    onClicked: { _ in self.onToggle() }
                )
            }
            .fixedSize(horizontal: true, vertical: false)
#if DEBUG
            .background {
                QuotaLayoutProbe(identifier: "reset")
            }
#endif
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

private struct QuotaLayoutProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> QuotaLayoutProbeView {
        QuotaLayoutProbeView(identifier: self.identifier)
    }

    func updateNSView(_ nsView: QuotaLayoutProbeView, context: Context) {}
}
#endif
