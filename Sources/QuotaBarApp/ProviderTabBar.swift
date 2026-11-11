import QuotaBarCore
import AppKit
import SwiftUI

/// Equal-width provider navigation. Quota readings belong to the selected card below.
///
/// Native buttons preserve keyboard focus and accessibility in the status popover.
struct ProviderTabBar: View {
    let selection: Provider
    let onSelect: (Provider) -> Void

    private static let providers = Provider.allCases
    /// ⌘1, ⌘2, … follow tab position, left to right.
    private static func shortcutKey(for provider: Provider) -> KeyEquivalent {
        KeyEquivalent(Character(String(Self.providers.firstIndex(of: provider)! + 1)))
    }
    private static let style = SegmentedSwitchStyle(segmentHeight: 26, inset: 2, cornerRadius: 7)
    private static let nameSize: CGFloat = 12
    /// Center the dot on the name's capitals rather than its full line box.
    private static let dotLift = NSFont.systemFont(ofSize: Self.nameSize).capHeight / 2

    var body: some View {
        SegmentedSwitch(
            options: Self.providers,
            selection: self.selection,
            style: Self.style,
            emphasisAnimation: {
                CostChartHoverMotion.systemReduceMotion ? nil : .easeOut(duration: 0.12)
            },
            edgeCurves: {
                TabSwitchMotion.edgeCurves(movingRight: $0, reduceMotion: CostChartHoverMotion.systemReduceMotion)
            },
            keyboardSelection: .cutAllAnimations,
            shortcut: { KeyboardShortcut(Self.shortcutKey(for: $0), modifiers: .command) },
            accessibilityLabel: { $0.displayName },
            selectedTraits: .isSelected,
            onSelect: self.onSelect
        ) { provider, isSelected, isEmphasized, emphasisAnimation in
            self.label(provider, isSelected: isSelected, isEmphasized: isEmphasized,
                       emphasisAnimation: emphasisAnimation)
        }
    }

    private func label(
        _ provider: Provider,
        isSelected: Bool,
        isEmphasized: Bool,
        emphasisAnimation: Animation?
    ) -> some View {
        // Align the provider dot with the name's capitals.
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Theme.accent(for: provider))
                .opacity(isEmphasized ? 1 : CostChartHighlightPolicy.restingOpacity)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.dotLift }
            // Reserve the semibold width so emphasis never shifts the label.
            // Crossfade fixed glyphs instead of swapping font metrics in a single frame.
            Text(provider.displayName)
                .font(.system(size: Self.nameSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .overlay {
                    ZStack {
                        Text(provider.displayName)
                            .font(.system(size: Self.nameSize, weight: .regular))
                            .opacity(isSelected ? 0 : 1)
                        Text(provider.displayName)
                            .font(.system(size: Self.nameSize, weight: .semibold))
                            .opacity(isSelected ? 1 : 0)
                    }
                    .fixedSize()
                }
        }
        .foregroundStyle(isEmphasized ? Color.primary : Color.primary.opacity(0.75))
        .animation(emphasisAnimation, value: isEmphasized)
        .animation(emphasisAnimation, value: isSelected)
    }
}
