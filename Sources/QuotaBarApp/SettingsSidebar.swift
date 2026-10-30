import SwiftUI

/// The settings window's panes.
enum SettingsTab: Int, CaseIterable, Identifiable {
    case general
    case pricing
    case usage

    var id: Int { self.rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .pricing: "Pricing"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .pricing: "dollarsign.circle"
        case .usage: "cylinder"
        }
    }

    /// ⌘1, ⌘2, and so on, the shortcuts a system tab bar would have given these panes.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character("\(self.rawValue + 1)"))
    }
}

/// The panes as a list down the window's side, under the close button. The window has no title
/// bar of its own, so the app's name sits here.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillSpace
    @State private var hovered: SettingsTab?
    @FocusState private var focusedTab: SettingsTab?

    static let width: CGFloat = 148

    private static let rowHeight: CGFloat = 32
    private static let cornerRadius: CGFloat = 7
    /// Clears the close button, which the transparent title bar leaves over the sidebar.
    private static let topInset: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("QuotaBar")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ForEach(SettingsTab.allCases) { tab in
                self.row(tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, Self.topInset)
        .padding(.bottom, 16)
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.055))
        .accessibilityElement(children: .contain)
    }

    private func row(_ tab: SettingsTab) -> some View {
        Button {
            self.select(tab)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: self.selection == tab ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background {
                if self.selection == tab {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.13))
                        .matchedGeometryEffect(id: "selection", in: self.pillSpace)
                } else {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .opacity(self.hovered == tab ? 1 : 0)
                        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.10), value: self.hovered)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion, pressScale: CardMotion.rowPressScale))
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .focused(self.$focusedTab, equals: tab)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(self.selection == tab ? [.isSelected] : [])
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(self.focusedTab == tab ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onHover { self.hovered = $0 ? tab : (self.hovered == tab ? nil : self.hovered) }
    }

    private func select(_ tab: SettingsTab) {
        guard tab != self.selection else { return }
        guard !TabSwitchMotion.isKeyboardInitiated else {
            TabSwitchMotion.cut { self.selection = tab }
            return
        }
        withAnimation(DisclosureMotion.open(reduceMotion: self.reduceMotion)) {
            self.selection = tab
        }
    }
}
