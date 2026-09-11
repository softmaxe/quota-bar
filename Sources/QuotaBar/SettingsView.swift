import QuotaBarCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pricing: PricingEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: SettingsTab = .general
    /// The pricing pane scans the cost database and refreshes the catalog when it first appears.
    /// Both panes live in the hierarchy so the switch can cross-fade, so that work is gated on
    /// the tab having actually been opened rather than on the view existing.
    @State private var pricingWasOpened = false

    private static let paneWidth: CGFloat = 620
    private static let paneHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: self.$tab)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            self.panes
        }
        .frame(width: Self.paneWidth)
        .onChange(of: self.tab) { _, newValue in
            if newValue == .pricing { self.pricingWasOpened = true }
        }
    }

    /// Both panes stay mounted; what changes is which one is opaque. The hidden one is disabled
    /// as well as transparent, so it takes neither a click nor the keyboard on its way out.
    private var panes: some View {
        ZStack(alignment: .topLeading) {
            self.pane(.general) { self.general }
            self.pane(.pricing) {
                PricingSettingsView(model: self.pricing, isLoadEnabled: self.pricingWasOpened)
            }
        }
        .frame(width: Self.paneWidth, height: Self.paneHeight, alignment: .topLeading)
    }

    private func pane(_ tab: SettingsTab, @ViewBuilder content: () -> some View) -> some View {
        let isActive = self.tab == tab
        return content()
            .opacity(isActive ? 1 : 0)
            .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: self.tab)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }

    private var general: some View {
        Form {
            Section {
                Picker("Refresh", selection: self.$settings.refreshFrequency) {
                    ForEach(RefreshFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                Text(self.refreshHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Menu bar") {
                Picker("Showing", selection: self.$settings.menuBarProvider) {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text("One item at a time. Pick it here or use the switch at the top of its "
                    + "menu. Sign-in status does not change this.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth, height: Self.paneHeight)
    }

    private var refreshHint: String {
        switch self.settings.refreshFrequency {
        case .manual:
            "Only refreshes when you open a menu or press ⌘R."
        case .oneMinute, .twoMinutes:
            "The quota endpoints are shared with the Codex and Claude CLIs. "
                + "Polling this often can get you rate-limited."
        default:
            "Opening the menu requests at most one additional refresh per minute without changing this schedule."
        }
    }
}
