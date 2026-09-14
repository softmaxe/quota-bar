import SwiftUI

/// The settings window's two panes. AppKit's own tab bar would draw this for free, but it offers
/// nowhere to put a curve — the selection jumps — so the control is drawn here instead.
enum SettingsTab: Int, CaseIterable, Identifiable {
    case general
    case pricing

    var id: Int { self.rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .pricing: "Pricing"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .pricing: "dollarsign.circle"
        }
    }

    /// ⌘1 and ⌘2, the shortcuts the system tab bar would have given these panes.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character("\(self.rawValue + 1)"))
    }
}

/// Two segments and one pill. The segments size themselves to their labels and report where they
/// landed; the pill is drawn from those frames, so nothing here assumes two equal halves of the
/// width or a fixed label.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bounds: [SettingsTab: CGRect] = [:]
    /// The pill's two edges, animated separately. This is the treatment: they carry the same
    /// curve over different durations, so the shape stretches across the gap and contracts onto
    /// the destination instead of sliding as a rigid block.
    @State private var pillMinX: CGFloat = 0
    @State private var pillMaxX: CGFloat = 0
    @State private var hovered: SettingsTab?
    @FocusState private var focusedTab: SettingsTab?

    private static let segmentHeight: CGFloat = 28
    private static let cornerRadius: CGFloat = 6
    private static let coordinateSpace = "SettingsTabBar.segments"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                self.segment(tab)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .background(alignment: .leading) { self.pill }
        .onPreferenceChange(SettingsTabBoundsKey.self) { value in
            self.bounds = value
            // First layout, and any later one that resizes the labels out from under the pill.
            if let rect = value[self.selection], rect.minX != self.pillMinX || rect.maxX != self.pillMaxX {
                if self.pillMaxX == 0 { self.snapPill(to: rect) }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ tab: SettingsTab) -> some View {
        Button {
            self.select(tab)
        } label: {
            ZStack {
                // Both weights are laid out, so the segment keeps one width while they trade
                // places. Animating a font weight is not a thing SwiftUI can do; this is.
                self.label(tab, weight: .semibold).opacity(self.selection == tab ? 1 : 0)
                self.label(tab, weight: .regular).opacity(self.selection == tab ? 0 : 1)
            }
            .foregroundStyle(self.selection == tab ? Color.white : Color.primary.opacity(0.85))
            .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: self.selection)
            .padding(.horizontal, 14)
            .frame(height: Self.segmentHeight)
            .background {
                // The wash an unselected segment carries under the pointer. A fade, nothing more:
                // it has to read as "clickable", not as a second selection.
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .opacity(self.hovered == tab && self.selection != tab ? 1 : 0)
                    .animation(
                        self.reduceMotion ? nil : .easeOut(duration: 0.10),
                        value: self.hovered
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(reduceMotion: self.reduceMotion))
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .focused(self.$focusedTab, equals: tab)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(self.selection == tab ? [.isSelected] : [])
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(self.selection == tab ? Color.white : Color.accentColor, lineWidth: 2)
                .opacity(self.focusedTab == tab ? 1 : 0)
                .allowsHitTesting(false)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsTabBoundsKey.self,
                    value: [tab: proxy.frame(in: .named(Self.coordinateSpace))]
                )
            }
        }
        .onHover { self.hovered = $0 ? tab : (self.hovered == tab ? nil : self.hovered) }
    }

    private func label(_ tab: SettingsTab, weight: Font.Weight) -> some View {
        Label(tab.title, systemImage: tab.symbol)
            .labelStyle(.titleOnly)
            .font(.system(size: 13, weight: weight))
            .fixedSize()
    }

    private var pill: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: max(0, self.pillMaxX - self.pillMinX), height: Self.segmentHeight)
            .offset(x: self.pillMinX)
    }

    private func select(_ tab: SettingsTab) {
        guard tab != self.selection, let rect = self.bounds[tab] else { return }
        let movingRight = rect.minX >= self.pillMinX
        let curves = TabSwitchMotion.edgeCurves(
            movingRight: movingRight,
            reduceMotion: self.reduceMotion
        )

        self.selection = tab
        // Two transactions, because the point is that the edges are not on one clock.
        withAnimation(curves.minX) { self.pillMinX = rect.minX }
        withAnimation(curves.maxX) { self.pillMaxX = rect.maxX }
    }

    private func snapPill(to rect: CGRect) {
        self.pillMinX = rect.minX
        self.pillMaxX = rect.maxX
    }
}

/// Where each segment ended up, in the bar's own coordinate space.
private struct SettingsTabBoundsKey: PreferenceKey {
    static var defaultValue: [SettingsTab: CGRect] = [:]

    static func reduce(value: inout [SettingsTab: CGRect], nextValue: () -> [SettingsTab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
