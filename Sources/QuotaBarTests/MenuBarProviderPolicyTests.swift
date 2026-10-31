import QuotaBarCore
import Foundation

/// What the provider switch and gauge read off each provider's last snapshot.
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

        let weeklyIsTighter = snapshot(
            .claude,
            session: UsageWindow(usedPercent: 36, resetsAt: later, windowSeconds: 18_000),
            weekly: UsageWindow(usedPercent: 72, resetsAt: later, windowSeconds: 604_800)
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.gaugeRemaining(weeklyIsTighter, now: now),
            64,
            "the gauge stays on the session window when the weekly one is tighter"
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.gaugeRemaining(unlimited, now: now),
            72,
            "the gauge falls back to the weekly window without a session window"
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.gaugeRemaining(drainedThenReset, now: now),
            100,
            "the gauge counts a session window past its reset as refilled"
        )
        Harness.expectEqual(
            MenuBarProviderPolicy.gaugeRemaining(snapshot(.codex, session: nil, weekly: nil), now: now),
            nil,
            "the gauge has nothing to show without windows"
        )
    }
}
