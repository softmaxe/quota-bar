#if DEBUG
import QuotaBarCore
import Foundation

/// Checks reset detection, provider isolation, and persistence.
enum QuotaRecoveryVerifier {
    @MainActor
    static func run() -> Never {
        let failures = Self.trackerFailures()
        return VerifierReport.finish(
            failures,
            label: "quota recovery verification",
            passed: "quota reset detection, five-hour/weekly hand-off, and persistence passed"
        )
    }

    // MARK: - Tracker

    @MainActor
    private static func trackerFailures() -> [String] {
        var failures: [String] = []
        let suite = "QuotaBarQuotaRecoveryVerifier"
        let defaults = EphemeralDefaults.make(suite)
        defer { EphemeralDefaults.clear(suite) }

        let tracker = QuotaRecoveryTracker(defaults: defaults)
        let epoch = Date(timeIntervalSince1970: 2_000_000_000)
        let first = Self.snapshot(
            provider: .claude,
            sessionRemaining: 37,
            sessionReset: epoch.addingTimeInterval(5 * 3600),
            weeklyRemaining: 62,
            weeklyReset: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(snapshot: first)
        if !tracker.pendingRecoveries(for: .claude).isEmpty {
            failures.append("the first reading was mistaken for a reset")
        }

        let spent = Self.snapshot(
            provider: .claude,
            sessionRemaining: 23,
            sessionReset: epoch.addingTimeInterval(5 * 3600),
            weeklyRemaining: 51,
            weeklyReset: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(snapshot: spent)
        if !tracker.pendingRecoveries(for: .claude).isEmpty {
            failures.append("ordinary spending with the same reset identity queued an animation")
        }

        let reset = Self.snapshot(
            provider: .claude,
            sessionRemaining: 100,
            sessionReset: epoch.addingTimeInterval(10 * 3600),
            weeklyRemaining: 100,
            weeklyReset: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        tracker.observe(snapshot: reset)
        let expected: [QuotaWindowKind: QuotaRecoveryEvent] = [
            .session: QuotaRecoveryEvent(fromRemainingPercent: 23),
            .weekly: QuotaRecoveryEvent(fromRemainingPercent: 51),
        ]
        if tracker.pendingRecoveries(for: .claude) != expected {
            failures.append("five-hour and weekly resets did not independently preserve their starting values")
        }
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("one provider's reset leaked into the other")
        }

        // Later polls must update the baseline without discarding a reset the card has not shown.
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 98,
            resetsAt: epoch.addingTimeInterval(10 * 3600)
        )
        if tracker.pendingRecoveries(for: .claude) != expected {
            failures.append("a later poll dropped a queued reset animation")
        }

        // Both the baseline and pending payload survive a process restart.
        let restarted = QuotaRecoveryTracker(defaults: defaults)
        if restarted.pendingRecoveries(for: .claude) != expected {
            failures.append("pending reset animations did not survive a restart")
        }
        if restarted.consumePending(for: .claude) != expected {
            failures.append("the card was not handed both reset windows with their starting values")
        }
        if !restarted.consumePending(for: .claude).isEmpty {
            failures.append("a reset animation was handed out twice")
        }

        // A large percentage jump alone is not a reset; the provider's reset identity is.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 12,
            resetsAt: epoch.addingTimeInterval(5 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(5 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a percentage jump with an unchanged reset identity was treated as a reset")
        }

        // A reset identity moving forward is not enough on its own. Codex can report a later
        // identity while the remaining quota has fallen, which must stay on the ordinary glide
        // path instead of playing a celebration backwards from 100% to the current reading.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(10 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 62,
            resetsAt: epoch.addingTimeInterval(15 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a forward reset identity with quota falling from 100 to 62 queued an animation")
            _ = tracker.consumePending(for: .codex)
        }

        // Claude reports the five-hour deadline it has already passed until real usage opens the
        // next window, so the quota returns to 100 several polls before the identity moves. The
        // recovery has to be caught at that reading, and must survive the identity catching up.
        let lagging = epoch.addingTimeInterval(20 * 3600)
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 3,
            resetsAt: lagging,
            now: lagging.addingTimeInterval(-600)
        )
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 100,
            resetsAt: lagging,
            now: lagging.addingTimeInterval(140)
        )
        let laggingExpected: [QuotaWindowKind: QuotaRecoveryEvent] = [
            .session: QuotaRecoveryEvent(fromRemainingPercent: 3),
        ]
        if tracker.pendingRecoveries(for: .claude) != laggingExpected {
            failures.append("a five-hour window recovering past its own deadline queued no animation")
        }
        tracker.observe(
            provider: .claude,
            kind: .session,
            remainingPercent: 94,
            resetsAt: lagging.addingTimeInterval(5 * 3600),
            now: lagging.addingTimeInterval(900)
        )
        if tracker.pendingRecoveries(for: .claude) != laggingExpected {
            failures.append("the identity catching up to a recovery already seen dropped its animation")
        }
        _ = tracker.consumePending(for: .claude)

        // Two rollovers with the first one never shown: the unobserved second window supersedes
        // the stale event instead of animating from a window that is two resets old.
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 8,
            resetsAt: epoch.addingTimeInterval(30 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(35 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 100,
            resetsAt: epoch.addingTimeInterval(40 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .session,
            remainingPercent: 71,
            resetsAt: epoch.addingTimeInterval(45 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("an event two rollovers old was still queued")
            _ = tracker.consumePending(for: .codex)
        }

        // An older response must not move the identity backwards and manufacture a future reset.
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 44,
            resetsAt: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 80,
            resetsAt: epoch.addingTimeInterval(7 * 24 * 3600)
        )
        tracker.observe(
            provider: .codex,
            kind: .weekly,
            remainingPercent: 43,
            resetsAt: epoch.addingTimeInterval(14 * 24 * 3600)
        )
        if !tracker.pendingRecoveries(for: .codex).isEmpty {
            failures.append("a stale response manufactured a weekly reset")
        }

        return failures
    }

    private static func snapshot(
        provider: Provider,
        sessionRemaining: Double,
        sessionReset: Date,
        weeklyRemaining: Double,
        weeklyReset: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            session: UsageWindow(
                usedPercent: 100 - sessionRemaining,
                resetsAt: sessionReset,
                windowSeconds: 5 * 3600
            ),
            weekly: UsageWindow(
                usedPercent: 100 - weeklyRemaining,
                resetsAt: weeklyReset,
                windowSeconds: 7 * 24 * 3600
            ),
            planLabel: nil,
            credits: nil,
            fetchedAt: Date()
        )
    }
}
#endif
