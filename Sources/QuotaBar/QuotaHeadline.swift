import SwiftUI

/// The authoritative reading for one quota window, above its progress bar.
struct QuotaHeadline: View {
    let title: String
    let percent: Double
    let tint: Color
    /// The bar's frame supplies a brief accent without changing the displayed reading.
    let frame: QuotaCelebrationFrame?

    /// Shared with the unlimited row in the same position.
    static let font = Font.system(size: 14, weight: .semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(self.title)
            Spacer(minLength: 8)
            Text("\(Formatters.percent(self.percent)) left")
                .monospacedDigit()
                .overlay {
                    Text("\(Formatters.percent(self.percent)) left")
                        .monospacedDigit()
                        .foregroundStyle(self.tint.opacity(self.accentOpacity))
                }
        }
        .font(Self.font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.title) \(Formatters.percent(self.percent)) left")
    }

    private var accentOpacity: Double {
        guard let frame, !frame.isReplay else { return 0 }
        return QuotaNumberMotion.accentOpacity(at: frame.elapsed)
    }
}
