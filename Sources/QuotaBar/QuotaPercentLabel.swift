import SwiftUI

/// The authoritative reading for one quota window, beside its progress bar.
struct QuotaPercentLabel: View {
    let percent: Double
    /// Orange for a window burning ahead of its pace, red for an empty one.
    let color: Color
    let tint: Color
    /// The bar's frame supplies a brief accent without changing the displayed reading.
    let frame: QuotaCelebrationFrame?

    var body: some View {
        Text(Formatters.percent(self.percent))
            .foregroundStyle(self.color)
            .overlay {
                Text(Formatters.percent(self.percent))
                    .foregroundStyle(self.tint.opacity(self.accentOpacity))
            }
    }

    private var accentOpacity: Double {
        guard let frame, !frame.isReplay else { return 0 }
        return QuotaNumberMotion.accentOpacity(at: frame.elapsed)
    }
}

/// Follows the frame the bar publishes while its reset plays.
struct RelayedQuotaPercentLabel: View {
    let percent: Double
    let color: Color
    let tint: Color
    @ObservedObject var relay: QuotaCelebrationRelay

    var body: some View {
        QuotaPercentLabel(percent: self.percent, color: self.color, tint: self.tint, frame: self.relay.frame)
    }
}
