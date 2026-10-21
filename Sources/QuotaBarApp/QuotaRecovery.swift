import QuotaBarCore
import Foundation

/// The value a reset animation resumes from. The destination stays the provider's new reading,
/// which is normally 100%, while this captures the final reading observed before the reset.
struct QuotaRecoveryEvent: Equatable {
    let fromRemainingPercent: Double
}

/// Detects real window rollovers from the provider's reset identity and remembers the animation
/// until the card claims it. Both the last reading and the pending event are persisted, so a
/// restart on either side of the rollover does not lose the transition.
@MainActor
final class QuotaRecoveryTracker {
    private let defaults: UserDefaults

    private enum Field: String {
        case lastReset
        case lastRemaining
        case pendingFrom
        /// The reset identity the pending event was recorded under, so a later identity can tell
        /// its own rollover from an older one the card never showed.
        case pendingReset
    }

    /// A rise smaller than this is the provider rounding its own percentage, not a window
    /// coming back.
    private static let recoveryEpsilon: Double = 0.5
    /// How far ahead of the recorded deadline a rise still counts as that window's reset, so a
    /// small disagreement between our clock and the provider's does not lose the animation.
    private static let deadlineGrace: TimeInterval = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ provider: Provider, _ kind: QuotaWindowKind, _ field: Field) -> String {
        "quota.rollover.\(provider.rawValue).\(kind.rawValue).\(field.rawValue)"
    }

    func observe(snapshot: UsageSnapshot) {
        // The reading's own timestamp, not the clock: a window that had already reset when the
        // response was built must be read against the time it was built.
        if let session = snapshot.session {
            self.observe(provider: snapshot.provider, kind: .session, window: session, now: snapshot.fetchedAt)
        }
        if let weekly = snapshot.weekly {
            self.observe(provider: snapshot.provider, kind: .weekly, window: weekly, now: snapshot.fetchedAt)
        }
    }

    func observe(
        provider: Provider,
        kind: QuotaWindowKind,
        window: UsageWindow,
        now: Date = Date()
    ) {
        self.observe(
            provider: provider,
            kind: kind,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            now: now
        )
    }

    func observe(
        provider: Provider,
        kind: QuotaWindowKind,
        remainingPercent: Double,
        resetsAt: Date?,
        now: Date = Date()
    ) {
        let remaining = min(100, max(0, remainingPercent))
        let resetKey = Self.key(provider, kind, .lastReset)
        let remainingKey = Self.key(provider, kind, .lastRemaining)

        let previousReset = (self.defaults.object(forKey: resetKey) as? NSNumber)?.doubleValue
        let previousRemaining = (self.defaults.object(forKey: remainingKey) as? NSNumber)?.doubleValue

        var currentReset = previousReset
        if let resetsAt {
            let reported = resetsAt.timeIntervalSince1970
            // A reset identity only moves forward. Ignore an older response rather than
            // downgrading the baseline and inventing a reset on the next good refresh.
            if let previousReset, reported < previousReset - 1 { return }
            currentReset = reported
        }

        if let previousReset, let previousRemaining {
            self.recordRollover(
                provider: provider,
                kind: kind,
                remaining: remaining,
                previousRemaining: previousRemaining,
                previousReset: previousReset,
                currentReset: currentReset ?? previousReset,
                now: now
            )
        }

        if let currentReset {
            self.defaults.set(currentReset, forKey: resetKey)
        }
        self.defaults.set(remaining, forKey: remainingKey)
    }

    /// Decides whether this reading is the moment the window came back, and keeps or supersedes
    /// an event the card has not shown yet.
    private func recordRollover(
        provider: Provider,
        kind: QuotaWindowKind,
        remaining: Double,
        previousRemaining: Double,
        previousReset: Double,
        currentReset: Double,
        now: Date
    ) {
        let pendingKey = Self.key(provider, kind, .pendingFrom)
        let pendingResetKey = Self.key(provider, kind, .pendingReset)

        let identityMovedForward = currentReset > previousReset + 1
        // Claude keeps reporting the five-hour deadline that has already gone by until real
        // usage opens the next window, so the quota comes back several polls before the identity
        // does. Once its own deadline has passed, a rise is that window resetting, whatever
        // identity the response still carries. Before the deadline it is only provider noise.
        let deadlinePassed = previousReset <= now.timeIntervalSince1970 + Self.deadlineGrace
        let recovered = remaining > previousRemaining + Self.recoveryEpsilon

        if recovered, identityMovedForward || deadlinePassed {
            var start = min(100, max(0, previousRemaining))
            // A window that climbs back in more than one poll still has to animate from where it
            // bottomed out, so an event already queued for this same window keeps its floor.
            if let queued = (self.defaults.object(forKey: pendingKey) as? NSNumber)?.doubleValue,
               let queuedReset = (self.defaults.object(forKey: pendingResetKey) as? NSNumber)?.doubleValue,
               abs(queuedReset - previousReset) <= 1 {
                start = min(start, min(100, max(0, queued)))
            }
            self.defaults.set(start, forKey: pendingKey)
            self.defaults.set(previousReset, forKey: pendingResetKey)
            return
        }

        // A later identity without an observed recovery means the rollover happened while we
        // were not looking. It supersedes an event from an older window the card never claimed,
        // but not the one queued for the window this identity is replacing.
        guard identityMovedForward, self.defaults.object(forKey: pendingKey) != nil else { return }
        let pendingReset = (self.defaults.object(forKey: pendingResetKey) as? NSNumber)?.doubleValue
        guard pendingReset == nil || pendingReset! < previousReset - 1 else { return }
        self.defaults.removeObject(forKey: pendingKey)
        self.defaults.removeObject(forKey: pendingResetKey)
    }

    /// Hands over every reset this provider has not shown yet. Session and weekly can both be
    /// present after the same refresh, and each carries its own pre-reset starting percentage.
    func consumePending(for provider: Provider) -> [QuotaWindowKind: QuotaRecoveryEvent] {
        var events: [QuotaWindowKind: QuotaRecoveryEvent] = [:]
        for kind in QuotaWindowKind.allCases {
            let key = Self.key(provider, kind, .pendingFrom)
            guard let value = (self.defaults.object(forKey: key) as? NSNumber)?.doubleValue else {
                continue
            }
            events[kind] = QuotaRecoveryEvent(fromRemainingPercent: min(100, max(0, value)))
            self.defaults.removeObject(forKey: key)
            self.defaults.removeObject(forKey: Self.key(provider, kind, .pendingReset))
        }
        return events
    }

#if DEBUG
    func pendingRecoveries(for provider: Provider) -> [QuotaWindowKind: QuotaRecoveryEvent] {
        var events: [QuotaWindowKind: QuotaRecoveryEvent] = [:]
        for kind in QuotaWindowKind.allCases {
            let key = Self.key(provider, kind, .pendingFrom)
            guard let value = (self.defaults.object(forKey: key) as? NSNumber)?.doubleValue else {
                continue
            }
            events[kind] = QuotaRecoveryEvent(fromRemainingPercent: min(100, max(0, value)))
        }
        return events
    }
#endif
}
