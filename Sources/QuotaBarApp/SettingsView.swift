import QuotaBarCore
import AppKit
import SwiftUI

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    /// Bumped whenever the pricing pane comes into view, so it rereads rates that a models.dev
    /// download or the General toggle changed while it sat mounted behind another pane.
    @Published var pricingReloads = 0
    /// Bumped whenever the window is shown, so General rereads what the price sources cover.
    @Published var windowShows = 0
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pricing: PricingTableModel
    @ObservedObject var store: UsageStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var selection: SettingsSelection = SettingsSelection()
    /// The pricing pane reads the cost database when it first appears.
    /// All panes live in the hierarchy so the switch can cross-fade, so that work is gated on
    /// the tab having actually been opened rather than on the view existing.
    @State private var pricingWasOpened = false

    static let paneWidth: CGFloat = 620
    static let paneHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: Binding(
                get: { self.selection.tab },
                set: { self.selection.tab = $0 }
            ))
            self.panes
        }
        .frame(width: Self.paneWidth)
        .onChange(of: self.selection.tab) { _, newValue in
            if newValue == .pricing {
                self.pricingWasOpened = true
                self.selection.pricingReloads += 1
            }
        }
        .onAppear {
            if self.selection.tab == .pricing { self.pricingWasOpened = true }
        }
    }

    /// All panes stay mounted; what changes is which one is opaque. Each hidden pane is disabled
    /// as well as transparent, so it takes neither a click nor the keyboard on its way out.
    private var panes: some View {
        ZStack(alignment: .topLeading) {
            self.pane(.general) {
                GeneralSettingsView(
                    settings: self.settings,
                    pricing: self.pricing,
                    store: self.store,
                    reload: self.selection.windowShows
                )
            }
            self.pane(.pricing) {
                PricingSettingsView(
                    model: self.pricing,
                    isLoadEnabled: self.pricingWasOpened,
                    reload: self.selection.pricingReloads
                )
            }
        }
        .frame(width: Self.paneWidth, height: Self.paneHeight, alignment: .topLeading)
    }

    private func pane(_ tab: SettingsTab, @ViewBuilder content: () -> some View) -> some View {
        let isActive = self.selection.tab == tab
        return content()
            .opacity(isActive ? 1 : 0)
            .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: self.selection.tab)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

/// General shows each choice as what it changes: the menu bar item as it is drawn now, each
/// provider with its live quota, the refresh cadences with the risky ones marked on the track,
/// and the price sources with what each one covers.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pricing: PricingTableModel
    @ObservedObject var store: UsageStore
    /// Changes whenever the window is shown, which rereads the price sources.
    var reload = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarPreview(
                provider: self.settings.menuBarProvider,
                display: self.display(self.settings.menuBarProvider)
            )

            self.sectionTitle("Menu bar")
            HStack(spacing: 10) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    ProviderChoiceCard(
                        provider: provider,
                        display: self.display(provider),
                        isSelected: self.settings.menuBarProvider == provider
                    ) {
                        withAnimation(DisclosureMotion.open(reduceMotion: self.reduceMotion)) {
                            self.settings.menuBarProvider = provider
                        }
                    }
                }
            }

            self.sectionTitle("Refresh")
            VStack(alignment: .leading, spacing: 8) {
                RefreshStopSlider(selection: self.$settings.refreshFrequency)
                Text(self.refreshHint)
                    .font(.system(size: 11))
                    .foregroundStyle(self.settings.refreshFrequency.risksRateLimit ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .settingsGroup()

            self.sectionTitle("Price sources")
            VStack(spacing: 0) {
                self.sourceRow(
                    symbol: "book.closed",
                    title: "Built-in price book",
                    detail: "Claude and OpenAI · \(self.pricing.priceBookModelCount) models"
                ) {
                    Text("Always on")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 50)
                self.sourceRow(
                    symbol: "globe",
                    title: "models.dev",
                    detail: self.modelsDevDetail
                ) {
                    Toggle("Price other models with models.dev", isOn: self.$settings.modelsDevPricing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .settingsGroup()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(width: SettingsView.paneWidth, height: SettingsView.paneHeight, alignment: .top)
        .task(id: [self.reload, self.settings.modelsDevPricing ? 1 : 0]) {
            self.pricing.loadSources()
        }
    }

    private func display(_ provider: Provider) -> ProviderDisplay {
        self.store.displays[provider] ?? ProviderDisplay()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 2)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func sourceRow(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var modelsDevDetail: String {
        guard self.settings.modelsDevPricing else {
            return "Off: models outside the price book stay unpriced"
        }
        guard let fetchedAt = self.pricing.modelsDevFetchedAt else {
            return "Everything else · not downloaded yet"
        }
        return "Everything else · \(self.pricing.modelsDevModelCount) models · "
            + "updated \(Formatters.relativeAge(since: fetchedAt))"
    }

    private var refreshHint: String {
        switch self.settings.refreshFrequency {
        case .manual:
            "Only refreshes when you open a menu or press ⌘R."
        case .oneMinute, .twoMinutes:
            "The quota endpoints are shared with the Codex and Claude CLIs. "
                + "Polling this often can get you rate-limited."
        default:
            "Opening the menu adds at most one extra refresh a minute."
        }
    }
}

extension RefreshFrequency {
    /// Polls often enough that the quota endpoints the CLIs share can start refusing requests.
    var risksRateLimit: Bool {
        self == .oneMinute || self == .twoMinutes
    }

    /// The label under the cadence's stop on the slider.
    var stopLabel: String {
        switch self {
        case .manual: "Manual"
        case .oneMinute: "1m"
        case .twoMinutes: "2m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        }
    }
}

private extension View {
    /// The rounded box each General section sits in.
    func settingsGroup() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
}

/// A slice of the menu bar with the status item drawn the way it is drawn now, so the provider
/// choice below reads as what it changes. The robot carries no numbers, so the caption says
/// what its color means.
struct MenuBarPreview: View {
    let provider: Provider
    let display: ProviderDisplay

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 10) {
                Text(self.caption(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(nsImage: self.icon(now: context.date))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    )
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                    .hour().minute())
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview: \(self.caption(now: Date()))")
    }

    private func runningLow(now: Date) -> Bool {
        self.display.snapshot.map { MenuBarProviderPolicy.runningLow($0, now: now) } ?? false
    }

    /// The same icon the status item draws for this provider, from the same cache.
    private func icon(now: Date) -> NSImage {
        IconRenderer.makeIcon(
            hasReading: self.display.snapshot?.session != nil || self.display.snapshot?.weekly != nil,
            stale: self.display.isStale,
            runningLow: self.runningLow(now: now)
        )
    }

    private func caption(now: Date) -> String {
        let name = self.provider.displayName
        if self.display.isSignedOut { return "\(name) is not signed in, so the robot is faded." }
        if self.display.isStale { return "The last \(name) refresh failed, so the robot is dimmed." }
        if self.runningLow(now: now) { return "\(name) is running low, so the robot is red." }
        return "The robot turns red when \(name) runs low."
    }
}

/// One provider as a choice for the menu bar, carrying the quota it would show.
struct ProviderChoiceCard: View {
    let provider: Provider
    let display: ProviderDisplay
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let accent = Theme.accent(for: self.provider)
        Button(action: self.select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                    Text(self.provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let plan = self.display.snapshot?.planLabel {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accent)
                        .opacity(self.isSelected ? 1 : 0)
                }
                Text(self.reading.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Capsule()
                    .fill(Theme.progressTrack)
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(accent)
                                .frame(width: geometry.size.width * (self.reading.fraction ?? 0))
                        }
                    }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(self.isSelected ? accent.opacity(0.10) : Color.primary.opacity(self.isHovered ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        self.isSelected ? accent : Color.primary.opacity(0.09),
                        lineWidth: self.isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
        .onHover { self.isHovered = $0 }
        .accessibilityLabel("\(self.provider.displayName), \(self.reading.text)")
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    /// The window the card reads from: the session one, or the weekly one when the plan has
    /// no session limit or the response left it out.
    private var reading: (text: String, fraction: Double?) {
        if self.display.isSignedOut { return ("Not signed in", nil) }
        guard let snapshot = self.display.snapshot else { return ("No reading yet", nil) }
        if let session = snapshot.session {
            return ("Session \(Formatters.percent(session.remainingPercent)) left", session.remainingPercent / 100)
        }
        if let weekly = snapshot.weekly {
            return ("Weekly \(Formatters.percent(weekly.remainingPercent)) left", weekly.remainingPercent / 100)
        }
        return (snapshot.sessionIsUnlimited ? "Session has no limit" : "No reading yet", nil)
    }
}

/// The refresh cadences as stops along a track. The span between the stops that poll often
/// enough to risk the CLIs' shared rate limit is drawn orange, so the risk shows where the
/// choice is made rather than in a paragraph under it.
struct RefreshStopSlider: View {
    @Binding var selection: RefreshFrequency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private static let stops = RefreshFrequency.allCases
    private static let knobSize: CGFloat = 16
    private static let trackHeight: CGFloat = 4

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                self.track(width: geometry.size.width)
            }
            .frame(height: Self.knobSize + 2)
            // Each label sits in an equal slice of the width; the stops are the slices' centers.
            HStack(spacing: 0) {
                ForEach(Self.stops) { stop in
                    Text(stop.stopLabel)
                        .font(.system(size: 10, weight: stop == self.selection ? .semibold : .regular))
                        .foregroundStyle(stop == self.selection ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { self.choose(stop) }
                }
            }
        }
        .focusable()
        .focused(self.$isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: self.step(by: -1)
            case .right, .up: self.step(by: 1)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refresh")
        .accessibilityValue(self.selection.label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: self.step(by: 1)
            case .decrement: self.step(by: -1)
            @unknown default: break
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let slice = width / CGFloat(Self.stops.count)
        let center = { (index: Int) in slice * (CGFloat(index) + 0.5) }
        let riskIndices = Self.stops.indices.filter { Self.stops[$0].risksRateLimit }
        let selectedIndex = Self.stops.firstIndex(of: self.selection) ?? 0

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.progressTrack)
                .frame(width: center(Self.stops.count - 1) - center(0), height: Self.trackHeight)
                .offset(x: center(0))
            if let first = riskIndices.first, let last = riskIndices.last {
                Rectangle()
                    .fill(Color.orange.opacity(0.75))
                    .frame(width: center(last) - center(first), height: Self.trackHeight)
                    .offset(x: center(first))
            }
            ForEach(Self.stops.indices, id: \.self) { index in
                Circle()
                    .fill(Self.stops[index].risksRateLimit ? Color.orange : Color.secondary.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .offset(x: center(index) - 2)
            }
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(self.isFocused ? 1 : 0)
                )
                .frame(width: Self.knobSize, height: Self.knobSize)
                .offset(x: center(selectedIndex) - Self.knobSize / 2)
        }
        .frame(width: width, height: Self.knobSize + 2, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                let index = Int((value.location.x / slice).rounded(.down))
                self.choose(Self.stops[max(0, min(Self.stops.count - 1, index))])
            }
        )
    }

    private func step(by offset: Int) {
        guard let index = Self.stops.firstIndex(of: self.selection) else { return }
        let next = index + offset
        guard Self.stops.indices.contains(next) else { return }
        self.choose(Self.stops[next])
    }

    private func choose(_ stop: RefreshFrequency) {
        guard stop != self.selection else { return }
        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.14)) {
            self.selection = stop
        }
    }
}
