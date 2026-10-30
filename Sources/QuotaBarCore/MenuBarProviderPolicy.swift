import Foundation

/// What the single menu bar item says about the providers' readings.
public enum MenuBarProviderPolicy {
    /// The remaining percentage of whichever window runs out first, which is the one that stops
    /// the next prompt.
    public static func tightestRemaining(_ snapshot: UsageSnapshot, now: Date) -> Double? {
        [snapshot.session, snapshot.weekly]
            .compactMap { $0 }
            .map { Self.remaining($0, now: now) }
            .min()
    }

    /// The remaining percentage the menu bar gauge shows: the session window, or the weekly window
    /// for a plan with no session cap.
    public static func gaugeRemaining(_ snapshot: UsageSnapshot, now: Date) -> Double? {
        (snapshot.session ?? snapshot.weekly).map { Self.remaining($0, now: now) }
    }

    /// Only the provider on show is refreshed, so the other one's reading can be hours old; a
    /// window whose reset time has already passed has refilled since it was read, and counts as
    /// full rather than as the empty it last reported.
    private static func remaining(_ window: UsageWindow, now: Date) -> Double {
        if let resetsAt = window.resetsAt, resetsAt <= now { return 100 }
        return window.remainingPercent
    }
}
