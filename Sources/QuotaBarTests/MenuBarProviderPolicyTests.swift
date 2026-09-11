import QuotaBarCore
import Foundation

/// What the provider switch and red icon read off each provider's last snapshot.
enum MenuBarProviderPolicyTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 10_000)
        let later = now.addingTimeInterval(3_600)
        let earlier = now.addingTimeInterval(-60)

        func snapshot(
            _ provider: Provider,
            session: UsageWindow?,
            weekly: UsageWindow?,
            sessionIsUnlimited: Bool = false
        ) -> UsageSnapshot {
            UsageSnapshot(
                provider: provider,
                session: session,
                weekly: weekly,
                planLabel: nil,
                credits: nil,
                fetchedAt: now,
                sessionIsUnlimited: sessionIsUnlimited
            )
        }

        let claude = snapshot(
            .claude,
            session: UsageWindow(usedPercent: 71, resetsAt: later, windowSeconds: 18_000),
            weekly: UsageWindow(usedPercent: 55, resetsAt: later, windowSeconds: 604_800)
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.tightestRemaining(claude, now: now),
            29,
            "the window with less left is the one reported"
        )

        let unlimited = snapshot(
            .codex,
            session: nil,
            weekly: UsageWindow(usedPercent: 28, resetsAt: later, windowSeconds: 604_800),
            sessionIsUnlimited: true
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.tightestRemaining(unlimited, now: now),
            72,
            "a plan with no session cap is bound by its weekly window"
        )

        Harness.expectEqual(
            MenuBarProviderPolicy.tightestRemaining(snapshot(.codex, session: nil, weekly: nil), now: now),
            nil,
            "a snapshot with no windows has nothing to report"
        )

        // The provider off screen is not refreshed, so its reading can predate a reset.
        let drainedThenReset = snapshot(
            .claude,
            session: UsageWindow(usedPercent: 96, resetsAt: earlier, windowSeconds: 18_000),
            weekly: UsageWindow(usedPercent: 40, resetsAt: later, windowSeconds: 604_800)
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.tightestRemaining(drainedThenReset, now: now),
            60,
            "a window past its reset counts as refilled"
        )

        let low = snapshot(
            .claude,
            session: UsageWindow(usedPercent: 90, resetsAt: later, windowSeconds: 18_000),
            weekly: UsageWindow(usedPercent: 40, resetsAt: later, windowSeconds: 604_800)
        )
        Harness.expect(
            MenuBarProviderPolicy.runningLow(low, now: now),
            "ninety percent used in either window counts as running low"
        )
        Harness.expect(
            !MenuBarProviderPolicy.runningLow(claude, now: now),
            "a provider with more than ten percent left is not running low"
        )
        Harness.expect(
            !MenuBarProviderPolicy.runningLow(drainedThenReset, now: now),
            "a window past its reset no longer counts as running low"
        )
        Harness.expect(
            !MenuBarProviderPolicy.runningLow(snapshot(.codex, session: nil, weekly: nil), now: now),
            "a snapshot with no windows is not running low"
        )
    }
}
