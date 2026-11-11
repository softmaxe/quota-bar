import QuotaBarCore
import SwiftUI

/// The Tokens / Cost switch in the local usage header, drawn like the provider tabs.
///
/// A native segmented control draws its track with vibrancy, which only blends with the popover
/// while nothing above it is translucent. The provider switch fades the card's content in, and
/// for those frames the native track lost its blending and flashed dark. Plain fills fade evenly.
struct UsageUnitSwitch: View {
    let selection: CostChartLabelMode
    let onSelect: (CostChartLabelMode) -> Void

    private static let modes: [CostChartLabelMode] = [.tokens, .cost]
    private static let style = SegmentedSwitchStyle(segmentHeight: 20, inset: 2, cornerRadius: 6)
    private static let labelSize: CGFloat = 12

    var body: some View {
        SegmentedSwitch(
            options: Self.modes,
            selection: self.selection,
            style: Self.style,
            emphasisAnimation: {
                CostChartHoverMotion.systemReduceMotion ? nil : .easeOut(duration: 0.12)
            },
            edgeCurves: {
                TabSwitchMotion.edgeCurves(movingRight: $0, reduceMotion: CostChartHoverMotion.systemReduceMotion)
            },
            keyboardSelection: .inheritTransaction,
            shortcut: { _ in nil },
            accessibilityLabel: Self.title,
            selectedTraits: .isSelected,
            onSelect: self.onSelect
        ) { mode, isSelected, isEmphasized, emphasisAnimation in
            Text(Self.title(of: mode))
                .font(.system(size: Self.labelSize, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isEmphasized ? Color.primary : Color.primary.opacity(0.75))
                .animation(emphasisAnimation, value: isEmphasized)
        }
    }

    private static func title(of mode: CostChartLabelMode) -> String {
        switch mode {
        case .tokens: "Tokens"
        case .cost: "Cost"
        }
    }
}
