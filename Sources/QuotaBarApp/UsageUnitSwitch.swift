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

    @State private var hovered: CostChartLabelMode?
    @FocusState private var focusedMode: CostChartLabelMode?
    @State private var pillMinX: CGFloat
    @State private var pillMaxX: CGFloat
    /// Only a click slides the pill. A mode restored from settings lands in place.
    @State private var clickedMode: CostChartLabelMode?

    private static let modes: [CostChartLabelMode] = [.tokens, .cost]
    private static let segmentHeight: CGFloat = 20
    private static let inset: CGFloat = 2
    private static let cornerRadius: CGFloat = 6
    private static let labelSize: CGFloat = 12

    init(selection: CostChartLabelMode, onSelect: @escaping (CostChartLabelMode) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
        let span = Self.span(of: selection)
        self._pillMinX = State(initialValue: span.minX)
        self._pillMaxX = State(initialValue: span.maxX)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.modes, id: \.self) { mode in
                Button { self.select(mode) } label: { self.segment(mode) }
                    .buttonStyle(ControlFeedbackStyle())
                    .focused(self.$focusedMode, equals: mode)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(self.focusedMode == mode ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .onHover { hovered in self.hovered = hovered ? mode : nil }
                    .accessibilityLabel(Self.title(of: mode))
                    .accessibilityAddTraits(mode == self.selection ? .isSelected : [])
            }
        }
        .frame(height: Self.segmentHeight)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                self.pill(width: geometry.size.width)
            }
        }
        .padding(Self.inset)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
        .onChange(of: self.selection) { _, newValue in
            let span = Self.span(of: newValue)
            let curves = TabSwitchMotion.edgeCurves(
                movingRight: span.minX >= self.pillMinX,
                reduceMotion: CostChartHoverMotion.systemReduceMotion
            )
            let animates = self.clickedMode == newValue
            self.clickedMode = nil
            withAnimation(animates ? curves.minX : nil) { self.pillMinX = span.minX }
            withAnimation(animates ? curves.maxX : nil) { self.pillMaxX = span.maxX }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ mode: CostChartLabelMode) -> some View {
        let isSelected = mode == self.selection
        let isEmphasized = isSelected || self.hovered == mode
        let emphasisAnimation: Animation? = CostChartHoverMotion.systemReduceMotion
            ? nil : .easeOut(duration: 0.12)
        return Text(Self.title(of: mode))
            .font(.system(size: Self.labelSize, weight: isSelected ? .medium : .regular))
            .lineLimit(1)
            .foregroundStyle(isEmphasized ? Color.primary : Color.primary.opacity(0.75))
            .animation(emphasisAnimation, value: isEmphasized)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .opacity(self.hovered == mode && !isSelected ? 1 : 0)
                    .animation(emphasisAnimation, value: self.hovered)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
    }

    private func pill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset, style: .continuous)
            .fill(ProviderTabBar.pillColor)
            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
            .frame(width: max(0, (self.pillMaxX - self.pillMinX) * width), height: Self.segmentHeight)
            .offset(x: self.pillMinX * width)
    }

    private func select(_ mode: CostChartLabelMode) {
        guard mode != self.selection else { return }
        self.clickedMode = TabSwitchMotion.isKeyboardInitiated ? nil : mode
        self.onSelect(mode)
    }

    private static func title(of mode: CostChartLabelMode) -> String {
        switch mode {
        case .tokens: "Tokens"
        case .cost: "Cost"
        }
    }

    private static func span(of mode: CostChartLabelMode) -> (minX: CGFloat, maxX: CGFloat) {
        let index = CGFloat(Self.modes.firstIndex(of: mode) ?? 0)
        let count = CGFloat(Self.modes.count)
        return (index / count, (index + 1) / count)
    }
}
