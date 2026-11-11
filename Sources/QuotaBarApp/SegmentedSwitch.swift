import AppKit
import SwiftUI

/// Geometry stays with each caller; both controls use the same plain, non-vibrant fills.
struct SegmentedSwitchStyle {
    let segmentHeight: CGFloat
    let inset: CGFloat
    let cornerRadius: CGFloat

    /// A raised white chip on a light menu, a lighter wash on a dark one.
    static let pillColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16)
            : NSColor(white: 1, alpha: 0.96)
    })
}

/// Equal-width custom segments with shared focus, hover, press, and selection feedback.
/// Labels and motion policies remain with the caller so the two switches keep their own behavior.
struct SegmentedSwitch<Option: Hashable, Label: View>: View {
    enum KeyboardSelection {
        case cutAllAnimations
        case inheritTransaction
    }

    let options: [Option]
    let selection: Option
    let style: SegmentedSwitchStyle
    let emphasisAnimation: () -> Animation?
    let edgeCurves: (Bool) -> (minX: Animation?, maxX: Animation?)
    let keyboardSelection: KeyboardSelection
    let shortcut: (Option) -> KeyboardShortcut?
    let accessibilityLabel: (Option) -> String
    let selectedTraits: AccessibilityTraits
    let onSelect: (Option) -> Void
    let label: (Option, Bool, Bool, Animation?) -> Label

    @State private var hovered: Option?
    @FocusState private var focused: Option?
    /// Separate edge transactions let the pill stretch toward the destination before settling.
    @State private var pillMinX: CGFloat
    @State private var pillMaxX: CGFloat
    /// Restored and keyboard selections land in place; only the last clicked option travels.
    @State private var clickedOption: Option?

    init(
        options: [Option],
        selection: Option,
        style: SegmentedSwitchStyle,
        emphasisAnimation: @escaping () -> Animation?,
        edgeCurves: @escaping (Bool) -> (minX: Animation?, maxX: Animation?),
        keyboardSelection: KeyboardSelection,
        shortcut: @escaping (Option) -> KeyboardShortcut?,
        accessibilityLabel: @escaping (Option) -> String,
        selectedTraits: AccessibilityTraits,
        onSelect: @escaping (Option) -> Void,
        @ViewBuilder label: @escaping (Option, Bool, Bool, Animation?) -> Label
    ) {
        self.options = options
        self.selection = selection
        self.style = style
        self.emphasisAnimation = emphasisAnimation
        self.edgeCurves = edgeCurves
        self.keyboardSelection = keyboardSelection
        self.shortcut = shortcut
        self.accessibilityLabel = accessibilityLabel
        self.selectedTraits = selectedTraits
        self.onSelect = onSelect
        self.label = label
        let span = Self.span(of: selection, in: options)
        self._pillMinX = State(initialValue: span.minX)
        self._pillMaxX = State(initialValue: span.maxX)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(self.options, id: \.self) { option in
                Button { self.select(option) } label: { self.segment(option) }
                    .buttonStyle(ControlFeedbackStyle())
                    .keyboardShortcut(self.shortcut(option))
                    .focused(self.$focused, equals: option)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardControlRadius)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(self.focused == option ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .onHover { hovered in self.hovered = hovered ? option : nil }
                    .accessibilityLabel(self.accessibilityLabel(option))
                    .accessibilityAddTraits(option == self.selection ? self.selectedTraits : [])
            }
        }
        .frame(height: self.style.segmentHeight)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                self.pill(width: geometry.size.width)
            }
        }
        .padding(self.style.inset)
        .background {
            RoundedRectangle(cornerRadius: self.style.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
        .onChange(of: self.selection) { _, newValue in
            let span = Self.span(of: newValue, in: self.options)
            let curves = self.edgeCurves(span.minX >= self.pillMinX)
            let animates = self.clickedOption == newValue
            self.clickedOption = nil
            // Two transactions keep the leading and trailing edges on their own clocks.
            withAnimation(animates ? curves.minX : nil) { self.pillMinX = span.minX }
            withAnimation(animates ? curves.maxX : nil) { self.pillMaxX = span.maxX }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == self.selection
        // Re-read Reduce Motion on local hover updates as well as parent selection updates.
        let emphasisAnimation = self.emphasisAnimation()
        return self.label(option, isSelected, isSelected || self.hovered == option, emphasisAnimation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Hover acknowledges an unselected segment without suggesting a second selection.
                RoundedRectangle(cornerRadius: Theme.cardControlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .opacity(self.hovered == option && !isSelected ? 1 : 0)
                    .animation(emphasisAnimation, value: self.hovered)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
    }

    private func pill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: self.style.cornerRadius - self.style.inset, style: .continuous)
            .fill(SegmentedSwitchStyle.pillColor)
            // A hairline edge and a contact shadow, as AppKit draws a selected segment.
            .overlay(
                RoundedRectangle(cornerRadius: self.style.cornerRadius - self.style.inset, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: max(0, (self.pillMaxX - self.pillMinX) * width), height: self.style.segmentHeight)
            .offset(x: self.pillMinX * width)
    }

    private func select(_ option: Option) {
        guard option != self.selection else { return }
        let isKeyboard = TabSwitchMotion.isKeyboardInitiated
        self.clickedOption = isKeyboard ? nil : option
        if isKeyboard, self.keyboardSelection == .cutAllAnimations {
            TabSwitchMotion.cut { self.onSelect(option) }
        } else {
            self.onSelect(option)
        }
    }

    private static func span(of option: Option, in options: [Option]) -> (minX: CGFloat, maxX: CGFloat) {
        let index = CGFloat(options.firstIndex(of: option) ?? 0)
        let count = CGFloat(options.count)
        return (index / count, (index + 1) / count)
    }
}
