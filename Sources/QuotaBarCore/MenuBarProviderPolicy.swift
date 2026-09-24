import Foundation

/// What the single menu bar item says about the providers' readings.
public enum MenuBarProviderPolicy {
    /// Remaining share at or below which a provider counts as running low.
    public static let lowRemainingPercent: Double = 10

    /// The remaining percentage of whichever window runs out first, which is the one that stops
    /// the next prompt. A reading can be older than its window's reset; a window whose reset time
    /// has already passed has refilled since it was read, and counts as full rather than as the
    /// empty it last reported.
    public static func tightestRemaining(_ snapshot: UsageSnapshot, now: Date) -> Double? {
        [snapshot.session, snapshot.weekly]
            .compactMap { $0 }
            .map { window in
                if let resetsAt = window.resetsAt, resetsAt <= now { return 100 }
                return window.remainingPercent
            }
            .min()
    }

    /// Whether a snapshot's tightest window has 10% or less left, i.e. 90% or more used.
    public static func runningLow(_ snapshot: UsageSnapshot, now: Date) -> Bool {
        guard let remaining = Self.tightestRemaining(snapshot, now: now) else { return false }
        return remaining <= Self.lowRemainingPercent
    }

    /// The tightest window across every provider's reading: the one the menu bar icon reports.
    public static func tightestRemaining(_ snapshots: [UsageSnapshot], now: Date) -> Double? {
        snapshots.compactMap { Self.tightestRemaining($0, now: now) }.min()
    }

    /// Whether the tightest window across every provider's reading is running low.
    public static func runningLow(_ snapshots: [UsageSnapshot], now: Date) -> Bool {
        guard let remaining = Self.tightestRemaining(snapshots, now: now) else { return false }
        return remaining <= Self.lowRemainingPercent
    }
}
