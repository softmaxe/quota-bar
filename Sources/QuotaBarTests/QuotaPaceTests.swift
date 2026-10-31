import Foundation
import QuotaBarCore

/// Which model reads a window's pace, and the line the menu shows for it, through `QuotaPace`.
enum QuotaPaceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let weekSeconds: TimeInterval = 7 * 86_400

    static func run() {
        self.weeklyPrefersPastWeeksOnceThereAreEnough()
        self.sessionReadsItsOwnTrail()
        self.summaryLines()
    }

    private static func weekly(used: Double) -> UsageWindow {
        UsageWindow(usedPercent: used, resetsAt: Self.now.addingTimeInterval(Self.weekSeconds / 2),
                    windowSeconds: Int(Self.weekSeconds))
    }

    /// Past weeks that spent 20% by mid-week and the rest after.
    private static func history(weeks: Int) -> UsageHistoryDataset {
        let resetsAt = Self.now.addingTimeInterval(Self.weekSeconds / 2)
        let grid = UsageWeekProfile.gridPointCount
        let curve = (0 ..< grid).map { index -> Double in
            let u = Double(index) / Double(grid - 1)
            return u <= 0.5 ? u * 40 : 20 + (u - 0.5) * 160
        }
        return UsageHistoryDataset(weeks: (1 ... weeks).reversed().map {
            UsageWeekProfile(resetsAt: resetsAt.addingTimeInterval(-Double($0) * Self.weekSeconds),
                             windowMinutes: 10_080, curve: curve)
        })
    }

    private static func weeklyPrefersPastWeeksOnceThereAreEnough() {
        let window = Self.weekly(used: 50)
        let linear = QuotaPace(history: Self.history(weeks: 2)).pace(for: .weekly, window: window, now: Self.now)
        Harness.expectEqual(linear?.stage, .onTrack, "two past weeks leave the weekly pace on the clock")

        let learned = QuotaPace(history: Self.history(weeks: 4)).pace(for: .weekly, window: window, now: Self.now)
        Harness.expect(learned?.stage.isAhead == true, "four past weeks read the same spend as a deficit")

        var pace = QuotaPace(history: Self.history(weeks: 4))
        pace.observe(UsageSnapshot(provider: .codex, session: nil, weekly: window, planLabel: nil,
                                   credits: nil, fetchedAt: Self.now))
        Harness.expectEqual(pace.history, Self.history(weeks: 4), "a reading without new history keeps what was learned")
    }

    /// A session that spent 60% in its first hour and then went still for twenty minutes is
    /// paused, which only its own readings can show.
    private static func sessionReadsItsOwnTrail() {
        let window = UsageWindow(usedPercent: 60, resetsAt: Self.now.addingTimeInterval(240 * 60), windowSeconds: 300 * 60)
        var pace = QuotaPace()
        for minutesAgo in [20.0, 10, 1] {
            pace.observe(UsageSnapshot(provider: .claude, session: window, weekly: nil, planLabel: nil,
                                       credits: nil, fetchedAt: Self.now.addingTimeInterval(-minutesAgo * 60)))
        }
        Harness.expectEqual(pace.sessionTrail.readings.count, 3, "each reading of the session joins its trail")
        let session = pace.pace(for: .session, window: window, now: Self.now)
        Harness.expect(session?.isIdle == true, "a still session reads as paused")
        Harness.expect(QuotaPace().pace(for: .session, window: window, now: Self.now)?.isIdle == false,
                       "without readings the same window cannot be called paused")
    }

    private static func summaryLines() {
        let minutes: (TimeInterval) -> String = { "\(Int($0 / 60))m" }
        func pace(eta: TimeInterval?, lasts: Bool = false, warming: Bool = false,
                  activeLeft: TimeInterval? = nil, delta: Double = 10) -> UsagePace {
            UsagePace(stage: UsagePace.stage(for: delta), deltaPercent: delta, expectedUsedPercent: 40,
                      etaSeconds: eta, willLastToReset: lasts, isWarmingUp: warming,
                      activeTimeLeftSeconds: activeLeft)
        }
        Harness.expectEqual(pace(eta: 1_800).summary(kind: .session, durationText: minutes), "Empty in about 30m",
                            "a session names when it empties")
        Harness.expectEqual(pace(eta: 0).summary(kind: .session, durationText: minutes), "Projected empty now",
                            "a session already at its projected end says so")
        Harness.expectEqual(pace(eta: 7_200).summary(kind: .weekly, durationText: minutes), "Runs out in 120m",
                            "a week names when it runs out")
        Harness.expectEqual(pace(eta: nil, lasts: true).summary(kind: .weekly, durationText: minutes), "Lasts until reset",
                            "a budget that lasts says so")
        Harness.expectEqual(pace(eta: nil, activeLeft: 2_400).summary(kind: .session, durationText: minutes), "40m of use left",
                            "a paused session counts working time")
        Harness.expectEqual(pace(eta: nil, warming: true).summary(kind: .weekly, durationText: minutes), "Estimating usage pace…",
                            "a fresh window says it is still estimating")
        Harness.expectEqual(pace(eta: nil).summary(kind: .weekly, durationText: minutes), "10% in deficit",
                            "with nothing to project, the line falls back to the delta")
    }
}
