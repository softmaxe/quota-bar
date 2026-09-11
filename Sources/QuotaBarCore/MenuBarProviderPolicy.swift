import Foundation

/// Which provider the single menu bar item shows, and where a right-click moves it.
public enum MenuBarProviderPolicy {
    /// Remaining share at or below which a provider counts as running low.
    public static let lowRemainingPercent: Double = 10

    /// The provider a right-click moves to, wrapping around the list. Provider data is
    /// intentionally not an input: a signed-out or not-yet-refreshed provider is still worth
    /// switching to, so its menu can explain itself instead of the item silently disappearing.
    public static func next(after provider: Provider) -> Provider {
        let all = Provider.allCases
        guard let index = all.firstIndex(of: provider) else { return all[0] }
        return all[(index + 1) % all.count]
    }

    /// The remaining percentage of whichever window runs out first, which is the one that stops
    /// the next prompt. Only the provider on show is refreshed, so the other one's reading can be
    /// hours old; a window whose reset time has already passed has refilled since it was read,
    /// and counts as full rather than as the empty it last reported.
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

    /// Whether a provider the item is not drawing is running low. The item shows one provider at
    /// a time, so this is the one thing it has to carry about the other.
    public static func otherProviderRunningLow(
        showing: Provider,
        snapshots: [Provider: UsageSnapshot],
        now: Date
    ) -> Bool {
        snapshots.contains { provider, snapshot in
            provider != showing && Self.runningLow(snapshot, now: now)
        }
    }
}
