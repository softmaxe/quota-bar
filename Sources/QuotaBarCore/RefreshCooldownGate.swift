import Foundation

/// One cooldown shared by every refresh path. Whatever caused the last refresh — the polling
/// timer, opening the menu, the Refresh action — the next minute serves the result already on
/// screen instead of hitting the quota endpoints again.
public struct RefreshCooldownGate {
    public static let defaultMinimumInterval: TimeInterval = 60
    /// A timer callback hops to the main actor before it claims, so a 60-second poll records its
    /// refresh a few milliseconds after the tick and the following tick lands just under the
    /// cooldown. Without slack the one-minute cadence would drop every other poll forever.
    public static let defaultTolerance: TimeInterval = 1

    private let minimumInterval: TimeInterval
    private let tolerance: TimeInterval
    private var lastRefreshTime: TimeInterval?

    public init(
        minimumInterval: TimeInterval = Self.defaultMinimumInterval,
        tolerance: TimeInterval = Self.defaultTolerance
    ) {
        self.minimumInterval = minimumInterval
        self.tolerance = tolerance
    }

    /// What `claimRefresh` actually enforces. The tolerance is folded in here so the countdown
    /// the menu shows can never disagree with whether a click would be honoured.
    private var effectiveInterval: TimeInterval {
        max(0, self.minimumInterval - self.tolerance)
    }

    /// Claims the current moment for a refresh when the cooldown has elapsed.
    public mutating func claimRefresh(at time: TimeInterval) -> Bool {
        guard self.remaining(at: time) == 0 else { return false }

        self.recordRefresh(at: time)
        return true
    }

    /// Seconds left before a refresh is allowed again; zero when one can run right now.
    public func remaining(at time: TimeInterval) -> TimeInterval {
        guard let lastRefreshTime else { return 0 }
        return max(0, lastRefreshTime + self.effectiveInterval - time)
    }

    /// Starts the cooldown for a refresh that ran without asking, so a forced one still quiets
    /// the minute after it.
    public mutating func recordRefresh(at time: TimeInterval) {
        self.lastRefreshTime = time
    }
}
