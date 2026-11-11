import SwiftUI

/// The authoritative reading for one quota window, above its progress bar.
struct QuotaHeadline: View {
    let title: String
    let percent: Double
    let tint: Color
    /// The bar's frame supplies a brief accent without changing the displayed reading.
    let frame: QuotaCelebrationFrame?
    /// A spent window shows its reading in red, so the row reads as blocked at a glance.
    var isExhausted = false
    /// A saved reading: the value steps back to secondary so it never passes for a fresh one.
    var isStale = false

    /// Shared with the unlimited row in the same position. The label is quieter than the value,
    /// so each row has one anchor: how much is left.
    static let font = Font.system(size: 13, weight: .medium)
    static let valueFont = Font.system(size: 15, weight: .semibold)
    static let unitFont = Font.system(size: 13, weight: .regular)

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(self.title)
                .font(Self.font)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Only the reading rolls; its unit keeps a quiet, steady baseline.
                Text(Formatters.percent(self.percent))
                    .monospacedDigit()
                    .font(Self.valueFont)
                    .foregroundStyle(self.isExhausted ? Color.red : self.isStale ? Color.secondary : Color.primary)
                    .rollingValue(self.percent, direction: self.percent)
                    .overlay {
                        Text(Formatters.percent(self.percent))
                            .monospacedDigit()
                            .rollingValue(self.percent, direction: self.percent)
                            .font(Self.valueFont)
                            .foregroundStyle(self.tint.opacity(self.accentOpacity))
                    }
                Text("left")
                    .font(Self.unitFont)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.title) \(Formatters.percent(self.percent)) left")
    }

    /// The label's small landing accent. It never changes, obscures, or moves the quota reading.
    private var accentOpacity: Double {
        guard let frame, !frame.isReplay else { return 0 }
        let age = frame.elapsed - QuotaCelebration.landing
        guard age >= 0, age < QuotaCelebration.flashDuration else { return 0 }
        return 0.35 * pow(1 - age / QuotaCelebration.flashDuration, 1.6)
    }
}
