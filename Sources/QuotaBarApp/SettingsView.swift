import QuotaBarCore
import ServiceManagement
import AppKit
import SwiftUI

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    /// Bumped whenever the pricing pane comes into view, so it rereads rates that a models.dev
    /// download changed while it sat mounted behind another pane.
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
    @ObservedObject var clock: SettingsClock = SettingsClock()
    /// The pricing pane reads the cost database when it first appears.
    /// All panes live in the hierarchy so the switch can cross-fade, so that work is gated on
    /// the tab having actually been opened rather than on the view existing.
    @State private var pricingWasOpened = false

    static let paneWidth: CGFloat = 672
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
                .environment(\.settingsNow, self.clock.now)
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
                GeneralSettingsView(settings: self.settings, store: self.store)
            }
            self.pane(.pricing) {
                PricingSettingsView(
                    settings: self.settings,
                    model: self.pricing,
                    isLoadEnabled: self.pricingWasOpened,
                    reload: self.selection.pricingReloads
                )
            }
            self.pane(.usage) {
                // Zero while the pane is out of view, so only opening it reads the database.
                UsageSettingsView(
                    settings: self.settings,
                    store: self.store,
                    remote: self.store.remoteSync,
                    backup: self.backup,
                    reload: self.selection.tab == .usage
                        ? self.selection.windowShows + self.store.finishedLocalScans + 1
                        : 0
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

/// General shows each choice as what it changes: each provider with its live quota, and the
/// refresh cadences with a warning for the risky ones.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPane("General") {
            SettingsSection("Show in menu bar") {
                VStack(spacing: 0) {
                    ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                        if index > 0 { Divider() }
                        ProviderChoiceRow(
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
                // Keeps a row's hover wash inside the box's corners.
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .settingsGroup()
            }

            SettingsSection("Behavior") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Refresh quota",
                        detail: self.settings.refreshFrequency.risksRateLimit
                            ? "The quota endpoints are shared with the Claude and Codex CLIs. "
                                + "Polling this often can get you rate-limited."
                            : "How often QuotaBar checks Claude and Codex for remaining quota.",
                        detailColor: self.settings.refreshFrequency.risksRateLimit ? .orange : .secondary
                    ) {
                        Picker("Refresh quota", selection: self.$settings.refreshFrequency) {
                            ForEach(RefreshFrequency.allCases) { frequency in
                                Text(frequency.label).tag(frequency)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Divider()
                    LaunchAtLoginRow()
                }
                .settingsGroup()
            }

            SettingsSection("About") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QuotaBar")
                            .font(.system(size: 13, weight: .medium))
                        Text(Self.versionText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Link(destination: Self.releasesURL) {
                        Text("Releases ↗")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .settingsGroup()
            }
        }
    }

    private static let releasesURL = URL(string: "https://github.com/softmaxe/quota-bar/releases")!

    private static var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development build"
        }
        return "Version \(version)"
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
            .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 22) {
                self.content()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .frame(width: SettingsView.paneWidth, height: SettingsView.paneHeight, alignment: .topLeading)
    }
}

extension SettingsPane where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// The heading above a settings section, with whatever acts on that section beside it.
struct SettingsSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(self.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            // Borderless, so the last control's text ends on the box's edge below it.
            self.accessory()
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 24)
    }
}

/// One titled part of a pane: its heading, whatever acts on that part, and what it holds.
struct SettingsSection<Accessory: View, Content: View>: View {
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
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(self.title, accessory: self.accessory)
            self.content()
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// One line of a settings section: what it is, a line about it, and its control.
struct SettingsRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol = self.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = self.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(self.detailColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            self.trailing()
        }
        .padding(.horizontal, 14)
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

    /// The wash a clickable settings row carries under the pointer.
    func settingsRowHover() -> some View {
        self.modifier(SettingsRowHover())
    }
}

private struct SettingsRowHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(self.isHovered && self.isEnabled ? 0.04 : 0))
            .onHover { self.isHovered = $0 }
    }
}

/// Opens QuotaBar when the user logs in, through the system's login item for this app. The
/// switch reads the system's record each time it appears, since System Settings can change it.
struct LaunchAtLoginRow: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var failure: String?

    var body: some View {
        SettingsRow(
            title: "Open at login",
            detail: self.failure ?? "Start QuotaBar in the menu bar when you log in.",
            detailColor: self.failure == nil ? .secondary : .orange
        ) {
            Toggle("Open at login", isOn: Binding(
                get: { self.isEnabled },
                set: { self.apply($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .onAppear { self.isEnabled = SMAppService.mainApp.status == .enabled }
        // The panes stay mounted, so coming back from System Settings is what rereads it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func apply(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.failure = nil
        } catch {
            self.failure = "macOS did not allow this change. Try again from System Settings › Login Items."
        }
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }
}

/// One provider as a radio row for the menu bar, with the reading it would show there.
struct ProviderChoiceRow: View {
    let provider: Provider
    let display: ProviderDisplay
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: self.select) {
            HStack(spacing: 10) {
                Image(systemName: self.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(self.isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(self.provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                if let plan = self.display.snapshot?.planLabel {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(self.display.quotaReading)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
        .settingsRowHover()
        .accessibilityLabel("\(self.provider.displayName), \(self.display.quotaReading)")
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }
}

extension ProviderDisplay {
    /// The window Settings reads from: the session one, or the weekly one when the plan has no
    /// session limit or the response left it out.
    var quotaReading: String {
        if self.isSignedOut { return "Not signed in" }
        guard let snapshot = self.snapshot else { return "No reading yet" }
        if let session = snapshot.session {
            return "Session \(Formatters.percent(session.remainingPercent)) left"
        }
        if let weekly = snapshot.weekly {
            return "Weekly \(Formatters.percent(weekly.remainingPercent)) left"
        }
        return snapshot.sessionIsUnlimited ? "Session has no limit" : "No reading yet"
    }
}
