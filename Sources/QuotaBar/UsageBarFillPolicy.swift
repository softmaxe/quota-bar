import Foundation

/// Decides how a usage bar should move when its value changes. Kept separate from the view so the
/// three cases — presentation, quota rollover, ordinary drift — can be asserted without SwiftUI.
enum UsageBarFillPolicy {
    enum Fill: Equatable {
        /// Show the provider's current reading immediately. Opening a card is not a quota event.
        case snap
        /// Snap to empty, then sweep left to right. Used for a window rollover.
        case sweepFromEmpty(duration: TimeInterval)
        /// Move from wherever the bar already sits, the way a value normally drifts.
        case glide(duration: TimeInterval)
    }

    /// A window that rolls over jumps the remaining percentage up by far more than spending ever
    /// moves it down between two refreshes, which is what separates a reset from ordinary drift.
    static let rolloverJumpPoints: Double = 5

    static let rolloverDuration: TimeInterval = 0.95
    static let glideDuration: TimeInterval = 0.35

    /// The value changed while the card was already on screen.
    static func onValueChange(from oldPercent: Double, to newPercent: Double) -> Fill {
        newPercent - oldPercent >= Self.rolloverJumpPoints
            ? .sweepFromEmpty(duration: Self.rolloverDuration)
            : .glide(duration: Self.glideDuration)
    }
}
