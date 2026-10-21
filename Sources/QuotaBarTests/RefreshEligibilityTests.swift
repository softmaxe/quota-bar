import Foundation
import QuotaBarCore

/// Every refresh path asks one module, and the Refresh row is read from the same rules.
enum RefreshEligibilityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() {
        self.eachProviderWaitsOutItsOwnMinute()
        self.serverRetryHoldsEveryPath()
        self.credentialRecoverySkipsOnlyTheLocalMinute()
        self.rowSpellsOutTheWait()
    }

    private static func claim(
        _ eligibility: inout RefreshEligibility,
        _ provider: Provider,
        by trigger: RefreshEligibility.Trigger = .automatic,
        given conditions: RefreshEligibility.Conditions = .init(),
        at uptime: TimeInterval
    ) -> Bool {
        eligibility.claim(provider, by: trigger, given: conditions, uptime: uptime, now: Self.now)
    }

    /// Refreshes are scoped to the provider on screen, so each provider waits out its own minute.
    private static func eachProviderWaitsOutItsOwnMinute() {
        var eligibility = RefreshEligibility()
        Harness.expect(Self.claim(&eligibility, .codex, at: 1_000), "the shown provider refreshes")
        Harness.expect(!Self.claim(&eligibility, .codex, at: 1_030), "and then waits out its minute")
        Harness.expect(!Self.claim(&eligibility, .codex, by: .user, at: 1_030),
                       "a user click without a credential to repair waits too")
        Harness.expectEqual(eligibility.remaining(.claude, given: .init(), uptime: 1_030, now: Self.now), 0,
                            "the provider that is not shown is untouched by that refresh")

        // Switching to the other provider is the one event that refreshes it, and switching back
        // and forth cannot buy extra fetches.
        Harness.expect(Self.claim(&eligibility, .claude, at: 1_030), "switching refreshes the provider switched to")
        Harness.expect(!Self.claim(&eligibility, .codex, at: 1_040), "switching back does not refetch within the minute")
        Harness.expect(!Self.claim(&eligibility, .claude, at: 1_050), "and neither does switching away and back")

        // Each minute elapses from its own provider's last refresh, with one second of slack for
        // a poll that claims just after its tick.
        Harness.expect(Self.claim(&eligibility, .codex, at: 1_059), "the first provider comes back a minute after its own refresh")
        Harness.expect(!Self.claim(&eligibility, .claude, at: 1_059), "which says nothing about the other one")
        Harness.expect(Self.claim(&eligibility, .claude, at: 1_089), "the other one comes back a minute after its own")

        eligibility.recordRefresh(.codex, uptime: 1_100)
        Harness.expectEqual(eligibility.remaining(.codex, given: .init(), uptime: 1_100, now: Self.now), 59,
                            "a refresh that ran anyway restarts that provider's minute")
        Harness.expectEqual(eligibility.remaining(.claude, given: .init(), uptime: 1_100, now: Self.now), 48,
                            "and leaves the other provider's running")

        let running = RefreshEligibility.Conditions(isRefreshing: true)
        var fresh = RefreshEligibility()
        Harness.expect(!Self.claim(&fresh, .codex, given: running, at: 0), "a running refresh blocks a second request")
    }

    /// A 429 is the server's call: nothing goes through before its retry date.
    private static func serverRetryHoldsEveryPath() {
        var eligibility = RefreshEligibility()
        let limited = RefreshEligibility.Conditions(serverRetryAfter: Self.now.addingTimeInterval(300))
        Harness.expect(!Self.claim(&eligibility, .codex, given: limited, at: 0), "polling waits for the server")
        Harness.expectEqual(eligibility.remaining(.codex, given: limited, uptime: 0, now: Self.now), 300,
                            "the wait is the server's when it is the longer one")
        let recovery = RefreshEligibility.Conditions(serverRetryAfter: Self.now.addingTimeInterval(300),
                                                     allowsCredentialRecovery: true)
        Harness.expect(!Self.claim(&eligibility, .codex, by: .user, given: recovery, at: 0),
                       "even a credential repair waits for the server")
        Harness.expect(!eligibility.canRefresh(.codex, given: recovery, uptime: 0, now: Self.now),
                       "and the row says so")
        Harness.expect(Self.claim(&eligibility, .codex, given: limited, at: 0) == false
                           && eligibility.remaining(.codex, given: .init(), uptime: 0, now: Self.now) == 0,
                       "a refused claim does not start the local minute")
        Harness.expect(Self.claim(&eligibility, .codex, given: .init(serverRetryAfter: Self.now), at: 0),
                       "the server's date passing lets the next refresh through")
    }

    /// The last refresh found a credential only the user may repair: their click skips the local
    /// minute once, and nothing else does.
    private static func credentialRecoverySkipsOnlyTheLocalMinute() {
        var eligibility = RefreshEligibility()
        _ = Self.claim(&eligibility, .claude, at: 1_000)
        let recovery = RefreshEligibility.Conditions(allowsCredentialRecovery: true)
        Harness.expect(!Self.claim(&eligibility, .claude, given: recovery, at: 1_010),
                       "an automatic refresh does not repair a credential early")
        Harness.expect(eligibility.canRefresh(.claude, given: recovery, uptime: 1_010, now: Self.now),
                       "the row offers the repair inside the minute")
        Harness.expect(Self.claim(&eligibility, .claude, by: .user, given: recovery, at: 1_010),
                       "a user click repairs it inside the minute")
        Harness.expectEqual(eligibility.remaining(.claude, given: .init(), uptime: 1_010, now: Self.now), 59,
                            "and restarts the minute")
    }

    private static func rowSpellsOutTheWait() {
        var eligibility = RefreshEligibility()
        Harness.expectEqual(eligibility.row(.codex, given: .init(), uptime: 0, now: Self.now), .idle,
                            "a provider never refreshed offers Refresh")
        _ = Self.claim(&eligibility, .codex, at: 1_000)
        Harness.expectEqual(
            eligibility.row(.codex, given: .init(), uptime: 1_058.5, now: Self.now),
            RefreshEligibility.Row(title: "Refresh", trailingText: "1s", isEnabled: false),
            "the countdown rounds up, so it never reads 0s while a click is refused"
        )
        Harness.expectEqual(
            eligibility.row(.codex, given: .init(isRefreshing: true), uptime: 1_010, now: Self.now),
            RefreshEligibility.Row(title: "Refreshing…", trailingText: nil, isEnabled: false, isInProgress: true),
            "a running refresh is reported as work, not as a countdown"
        )
        Harness.expectEqual(
            eligibility.row(.codex, given: .init(isSignedOut: true), uptime: 1_059, now: Self.now),
            RefreshEligibility.Row(title: "Check sign-in", trailingText: nil, isEnabled: true),
            "a signed-out provider offers to check sign-in"
        )
        Harness.expectEqual(
            eligibility.row(.codex, given: .init(isRefreshing: true, isSignedOut: true), uptime: 1_059, now: Self.now).title,
            "Checking…",
            "and says it is checking while it does"
        )
        Harness.expectEqual(
            eligibility.row(
                .codex,
                given: .init(serverRetryAfter: Self.now.addingTimeInterval(120), allowsCredentialRecovery: true),
                uptime: 1_010,
                now: Self.now
            ).trailingText,
            "120s",
            "a repair held by the server counts down the server's wait"
        )
    }
}
