import QuotaBarCore
import AppKit
import SwiftUI

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    /// Bumped whenever the pricing pane comes into view, so it rereads rates that a models.dev
    /// download or the General toggle changed while it sat mounted behind another pane.
    @Published var pricingReloads = 0
    /// Bumped whenever the window is shown, so the open pane rereads what it shows.
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
                    store: self.store
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
                // Zero while the pane is out of view, so only opening it reads the mirrors.
                RemoteSettingsView(
                    settings: self.settings,
                    remote: self.store.remoteSync,
                    reload: self.selection.tab == .remote
                        ? self.selection.windowShows + self.store.finishedLocalScans + 1
                        : 0
                )
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

/// General shows each choice as what it changes: each provider with its live quota, the refresh
/// cadences with a warning for the risky ones, and the price sources.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPane("General") {
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
                if self.settings.refreshFrequency.risksRateLimit {
                    Text(
                        "The quota endpoints are shared with the Codex and Claude CLIs. "
                            + "Polling this often can get you rate-limited."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .settingsGroup()

            SettingsSectionTitle("Price sources")
            VStack(spacing: 0) {
                SettingsRow(
                    symbol: "book.closed",
                    title: "Built-in price book"
                ) {
                    Text("Always on")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 50)
                SettingsRow(
                    symbol: "globe",
                    title: "models.dev"
                ) {
                    Toggle("Price other models with models.dev", isOn: self.$settings.modelsDevPricing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .settingsGroup()
        }
    }

    private func display(_ provider: Provider) -> ProviderDisplay {
        self.store.displays[provider] ?? ProviderDisplay()
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

/// One line of a settings section: what it is and its control.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
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
            Text(self.title)
                .font(.system(size: 13))
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
