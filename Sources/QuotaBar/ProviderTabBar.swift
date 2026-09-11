import QuotaBarCore
import AppKit
import SwiftUI

/// The card's provider switch: one segment per provider, each carrying what its tightest window
/// has left, so the provider off screen can be read without switching to it.
///
/// Clicks and hover arrive through `MouseLocationReader`: the card lives in an NSMenu popup, which
/// is never the key window, so a SwiftUI button or gesture here would never fire.
struct ProviderTabBar: View {
    let selection: Provider
    /// The tightest window's remaining percentage, for each provider that has been read.
    let remaining: [Provider: Double]
    let onSelect: (Provider) -> Void

    @State private var hovered: Provider?
    /// The pill's two edges as fractions of the bar's width. They travel on separate curves, the
    /// way the settings tabs do, so the pill stretches across and settles rather than sliding.
    @State private var pillMinX: CGFloat
    @State private var pillMaxX: CGFloat
    /// The provider this bar was just clicked over to. Only that change animates: a provider
    /// switched while the menu was closed lands on the next open without a pill sweeping past.
    @State private var clickedProvider: Provider?

    private static let providers = Provider.allCases
    private static let segmentHeight: CGFloat = 22
    private static let inset: CGFloat = 2
    private static let cornerRadius: CGFloat = 7

    /// A raised white chip on a light menu, a lighter wash on a dark one.
    private static let pillColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16)
            : NSColor(white: 1, alpha: 0.96)
    })

    init(selection: Provider, remaining: [Provider: Double], onSelect: @escaping (Provider) -> Void) {
        self.selection = selection
        self.remaining = remaining
        self.onSelect = onSelect
        let span = Self.span(of: selection)
        self._pillMinX = State(initialValue: span.minX)
        self._pillMaxX = State(initialValue: span.maxX)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.providers, id: \.self) { provider in
                self.segment(provider)
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
        .mouseLocation(
            onMoved: { location, width in
                let provider = location.map { Self.provider(at: $0.x, width: width) }
                guard provider != self.hovered else { return }
                self.hovered = provider
            },
            onClicked: { location, width in
                self.select(Self.provider(at: location.x, width: width))
            }
        )
        .onChange(of: self.selection) { _, newValue in
            let span = Self.span(of: newValue)
            let curves = TabSwitchMotion.edgeCurves(
                movingRight: span.minX >= self.pillMinX,
                reduceMotion: CostChartHoverMotion.systemReduceMotion
            )
            let animates = self.clickedProvider == newValue
            self.clickedProvider = nil
            // Two transactions, because the point is that the edges are not on one clock.
            withAnimation(animates ? curves.minX : nil) { self.pillMinX = span.minX }
            withAnimation(animates ? curves.maxX : nil) { self.pillMaxX = span.maxX }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ provider: Provider) -> some View {
        let isSelected = provider == self.selection
        return HStack(spacing: 5) {
            Circle()
                .fill(Theme.accent(for: provider))
                .frame(width: 6, height: 6)
            ZStack {
                // Both weights are laid out, so the segment keeps one width while they trade
                // places on selection.
                self.name(provider, weight: .semibold).opacity(isSelected ? 1 : 0)
                self.name(provider, weight: .regular).opacity(isSelected ? 0 : 1)
            }
            if let remaining = self.remaining[provider] {
                Text(Formatters.percent(remaining))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The wash an unselected segment carries under the pointer: it says "clickable"
            // without reading as a second selection.
            RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .opacity(self.hovered == provider && !isSelected ? 1 : 0)
                .animation(.easeOut(duration: 0.14), value: self.hovered)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel(provider))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { self.select(provider) }
    }

    private func name(_ provider: Provider, weight: Font.Weight) -> some View {
        Text(provider.displayName)
            .font(.system(size: 12, weight: weight))
            .lineLimit(1)
            .fixedSize()
    }

    private func pill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset, style: .continuous)
            .fill(Self.pillColor)
            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
            .frame(width: max(0, (self.pillMaxX - self.pillMinX) * width), height: Self.segmentHeight)
            .offset(x: self.pillMinX * width)
    }

    private func select(_ provider: Provider) {
        guard provider != self.selection else { return }
        self.clickedProvider = provider
        self.onSelect(provider)
    }

    private func accessibilityLabel(_ provider: Provider) -> String {
        guard let remaining = self.remaining[provider] else { return provider.displayName }
        return "\(provider.displayName), \(Formatters.percent(remaining)) left"
    }

    /// Equal segments, so a provider's slot is a fixed share of the width.
    private static func span(of provider: Provider) -> (minX: CGFloat, maxX: CGFloat) {
        let index = CGFloat(Self.providers.firstIndex(of: provider) ?? 0)
        let count = CGFloat(Self.providers.count)
        return (index / count, (index + 1) / count)
    }

    private static func provider(at x: CGFloat, width: CGFloat) -> Provider {
        guard width > 0 else { return Self.providers[0] }
        let index = Int((x / width) * CGFloat(Self.providers.count))
        return Self.providers[max(0, min(Self.providers.count - 1, index))]
    }
}
