import CoreGraphics
import Foundation

/// One frame of the reset choreography, as the bar is drawing it. The headline reads its elapsed
/// time only for a brief accent; the displayed percentage always comes from live quota data.
struct QuotaCelebrationFrame: Equatable {
    /// Seconds into the sequence.
    let elapsed: TimeInterval
    /// The percentage the fill is showing at this instant.
    let percent: Double
    /// The hidden replay returns to the live reading instead of stopping at 100%.
    let isReplay: Bool
}

/// The bar publishes its choreography here and the headline reads it. Only the two of them
/// re-render per frame; the rest of the card never sees the clock.
@MainActor
final class QuotaCelebrationRelay: ObservableObject {
    /// Nil whenever nothing is playing.
    @Published fileprivate(set) var frame: QuotaCelebrationFrame?

    func publish(_ frame: QuotaCelebrationFrame?) {
        self.frame = frame
    }
}

/// The label's small landing accent. It never changes, obscures, or moves the quota reading.
enum QuotaNumberMotion {
    static func accentOpacity(at time: TimeInterval) -> Double {
        let age = time - QuotaCelebration.landing
        guard age >= 0, age < QuotaCelebration.flashDuration else { return 0 }
        return 0.35 * pow(1 - age / QuotaCelebration.flashDuration, 1.6)
    }
}
