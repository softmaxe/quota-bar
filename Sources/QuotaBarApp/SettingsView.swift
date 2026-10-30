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
    @ObservedObject var backup: UsageBackupModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var selection: SettingsSelection = SettingsSelection()
    /// The pricing pane reads the cost database when it first appears.
    /// All panes live in the hierarchy so the switch can cross-fade, so that work is gated on
    /// the tab having actually been opened rather than on the view existing.
    @State private var pricingWasOpened = false

    static let paneWidth: CGFloat = 620
    static let paneHeight: CGFloat = 540
    /// The sidebar, the one-point divider, and a pane.
    static let windowSize = NSSize(width: SettingsSidebar.width + 1 + paneWidth, height: paneHeight)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: Binding(
                    get: { self.selection.tab },
                    set: { self.selection.tab = $0 }
                )
            )
            Divider()
            self.panes
        }
        .frame(height: Self.paneHeight)
        // The sidebar runs up behind the transparent title bar.
        .ignoresSafeArea(.container, edges: .top)
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
            self.pane(.remote) {
                RemoteSettingsView(settings: self.settings, remote: self.store.remoteSync)
            }
            self.pane(.data) {
                // Zero while the pane is out of view, so only opening it reads the database.
                DataSettingsView(
                    model: self.backup,
                    reload: self.selection.tab == .data ? self.selection.windowShows + 1 : 0
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
/// provider with its live quota, the refresh cadences with a warning for the risky ones, and the
/// price sources with what each one covers.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pricing: PricingTableModel
    @ObservedObject var store: UsageStore
    /// Changes whenever the window is shown, which rereads the price sources.
    var reload = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPane("General") {
            MenuBarPreview(
                provider: self.settings.menuBarProvider,
                display: self.display(self.settings.menuBarProvider)
            )

            SettingsSectionTitle("Menu bar")
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

            SettingsSectionTitle("Refresh")
            VStack(alignment: .leading, spacing: 8) {
                Picker("Refresh", selection: self.$settings.refreshFrequency) {
                    ForEach(RefreshFrequency.allCases) { frequency in
                        Text(frequency.shortLabel).tag(frequency)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(self.refreshHint)
                    .font(.system(size: 11))
                    .foregroundStyle(self.settings.refreshFrequency.risksRateLimit ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .settingsGroup()

            SettingsSectionTitle("Price sources")
            VStack(spacing: 0) {
                SettingsRow(
                    symbol: "book.closed",
                    title: "Built-in price book",
                    detail: "Claude and OpenAI · \(self.pricing.priceBookModelCount) models"
                ) {
                    Text("Always on")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 50)
                SettingsRow(
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
        .task(id: [self.reload, self.settings.modelsDevPricing ? 1 : 0]) {
            self.pricing.loadSources()
        }
    }

    private func display(_ provider: Provider) -> ProviderDisplay {
        self.store.displays[provider] ?? ProviderDisplay()
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

    /// The label on the cadence's segment.
    var shortLabel: String {
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

/// One pane of the settings window: its name, whatever acts on the whole pane beside that, and
/// what it holds.
struct SettingsPane<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                self.accessory()
            }
            .frame(height: 24)
            .padding(.bottom, 12)
            self.content()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(width: SettingsView.paneWidth, height: SettingsView.paneHeight, alignment: .topLeading)
    }
}

extension SettingsPane where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// The heading above a settings section.
struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(self.title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 2)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}

/// One line of a settings section: what it is, a line about it, and its control.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.system(size: 13))
                if let detail = self.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            self.trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

extension View {
    /// The rounded box each settings section sits in.
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
/// choice below reads as what it changes. The gauge carries no numbers, so the caption says
/// which quota it shows.
struct MenuBarPreview: View {
    let provider: Provider
    let display: ProviderDisplay

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 10) {
                Text(self.caption)
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
        .accessibilityLabel("Menu bar preview: \(self.caption)")
    }

    /// The same icon the status item draws for this provider, from the same cache.
    private func icon(now: Date) -> NSImage {
        IconRenderer.makeIcon(
            remainingPercent: self.display.snapshot.flatMap { MenuBarProviderPolicy.gaugeRemaining($0, now: now) },
            stale: self.display.isStale
        )
    }

    private var caption: String {
        let name = self.provider.displayName
        if self.display.isSignedOut { return "\(name) is not signed in, so the gauge is faded." }
        if self.display.isStale { return "The last \(name) refresh failed, so the gauge is dimmed." }
        let usesWeekly = self.display.snapshot?.session == nil && self.display.snapshot?.weekly != nil
        return "The gauge shows \(name)'s \(usesWeekly ? "weekly" : "session") quota."
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
                Text(self.display.quotaReading.text)
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
                                .frame(width: geometry.size.width * (self.display.quotaReading.fraction ?? 0))
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
        .accessibilityLabel("\(self.provider.displayName), \(self.display.quotaReading.text)")
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }
}

extension ProviderDisplay {
    /// The window Settings reads from: the session one, or the weekly one when the plan has no
    /// session limit or the response left it out.
    var quotaReading: (text: String, fraction: Double?) {
        if self.isSignedOut { return ("Not signed in", nil) }
        guard let snapshot = self.snapshot else { return ("No reading yet", nil) }
        if let session = snapshot.session {
            return ("Session \(Formatters.percent(session.remainingPercent)) left", session.remainingPercent / 100)
        }
        if let weekly = snapshot.weekly {
            return ("Weekly \(Formatters.percent(weekly.remainingPercent)) left", weekly.remainingPercent / 100)
        }
        return (snapshot.sessionIsUnlimited ? "Session has no limit" : "No reading yet", nil)
    }
}
