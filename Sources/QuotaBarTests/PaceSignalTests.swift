import QuotaBarCore
import Foundation

/// Signals that sharpen the linear pace: recent session readings, pauses, and the daily rhythm
/// that measures a weekly window in active hours.
enum PaceSignalTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    /// Midnight UTC, so hour-of-day arithmetic in the rhythm tests is easy to read.
    private static let midnight = Date(timeIntervalSince1970: 1_799_971_200)

    static func run() {
        Self.labels()
        Self.trail()
        Self.pausedSession()
        Self.recentSession()
        Self.rhythmArithmetic()
        Self.rhythmLearning()
        Self.weeklyRhythm()
    }

    private static func sessionWindow(used: Double, elapsedMinutes: Double, now: Date) -> UsageWindow {
        UsageWindow(
            usedPercent: used,
            resetsAt: now.addingTimeInterval((300 - elapsedMinutes) * 60),
            windowSeconds: 300 * 60
        )
    }

    private static func trail(_ window: UsageWindow, _ points: [(minutesAgo: Double, used: Double)], now: Date) -> UsageTrail {
        UsageTrail(readings: points.map {
            UsageTrail.Reading(
                sampledAt: now.addingTimeInterval(-$0.minutesAgo * 60),
                usedPercent: $0.used,
                resetsAt: window.resetsAt!
            )
        })
    }

    private static func labels() {
        let now = Self.midnight
        // A large reserve once printed a fixed "1.5× headroom" whatever the multiplier was.
        let light = UsagePace.evaluate(
            window: UsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3.5 * 86_400), windowSeconds: 604_800),
            context: .weekly,
            now: now
        )
        Harness.expectEqual(
            light?.etaLabel(context: .weekly, durationText: { "\(Int($0))s" }),
            "Lasts until reset",
            "the lasting label carries no invented multiplier"
        )
        Harness.expectEqual(light?.headroomLabel, "9.0× headroom at current pace", "headroom shows the real multiplier")
    }

    private static func trail() {
        let now = Self.midnight
        var trail = UsageTrail()
        let first = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(3600), windowSeconds: 18_000)
        let next = UsageWindow(usedPercent: 2, resetsAt: now.addingTimeInterval(5 * 3600), windowSeconds: 18_000)
        trail.append(first, at: now.addingTimeInterval(-60))
        trail.append(first, at: now.addingTimeInterval(-120))
        Harness.expectEqual(trail.readings.count, 1, "an out-of-order reading is ignored")
        trail.append(next, at: now)
        Harness.expectEqual(trail.readings.map(\.usedPercent), [2], "a new window drops the old window's readings")
        trail.append(next, at: now.addingTimeInterval(3 * 3600))
        Harness.expectEqual(trail.readings.count, 1, "readings past the horizon are dropped")
    }

    private static func pausedSession() {
        let now = Self.midnight
        // 60% gone in the first hour, then nothing for twenty minutes.
        let window = Self.sessionWindow(used: 60, elapsedMinutes: 60, now: now)
        let still = Self.trail(window, [(20, 60), (10, 60), (1, 60)], now: now)
        let paused = UsagePace.evaluate(window: window, context: .session, now: now, trail: still)
        Harness.expectClose(paused?.activeTimeLeftSeconds, 40 * 60, "a pause reports working time left at the earlier pace")
        let burst = Self.trail(window, [(50, 30), (20, 60), (1, 60)], now: now)
        // 30 points in the 30 minutes before the pause, 60 over the hour since the reset.
        let beforePause: Double = 30.0 / 1800
        let average: Double = 60.0 / 3600
        let burstRate: Double = 0.65 * beforePause + 0.35 * average
        Harness.expectClose(
            UsagePace.evaluate(window: window, context: .session, now: now, trail: burst)?.activeTimeLeftSeconds,
            40 / burstRate,
            "working time left blends the pace just before the pause",
            tolerance: 1e-6
        )
        Harness.expect(paused?.etaSeconds == nil && paused?.willLastToReset == false,
                       "a paused session neither empties at a clock time nor promises to last")
        Harness.expectEqual(
            paused?.etaLabel(context: .session, durationText: { "\(Int($0 / 60))m" }),
            "Paused · about 40m of use left",
            "the paused label speaks in working time"
        )

        // One reading twenty minutes ago says nothing about the time since.
        let single = Self.trail(window, [(20, 60)], now: now)
        let unobserved = UsagePace.evaluate(window: window, context: .session, now: now, trail: single)
        Harness.expect(unobserved?.isIdle == false, "unobserved time is not a pause")
        Harness.expectClose(unobserved?.etaSeconds, 40 * 60, "without recent readings the average pace applies")

        // A pause only matters while the earlier pace would still run dry.
        let lightWindow = Self.sessionWindow(used: 10, elapsedMinutes: 60, now: now)
        let lightStill = Self.trail(lightWindow, [(20, 10), (1, 10)], now: now)
        let light = UsagePace.evaluate(window: lightWindow, context: .session, now: now, trail: lightStill)
        Harness.expect(light?.isIdle == false && light?.willLastToReset == true,
                       "a light session that stops is simply lasting")

        // Steady light use after an early burst: one point every fifteen minutes. The reading
        // holds between steps for longer than ten minutes, but that is not a pause.
        let steadyWindow = Self.sessionWindow(used: 54, elapsedMinutes: 120, now: now)
        let steps = Self.trail(steadyWindow, [(60, 50), (45, 51), (30, 52), (15, 53), (13, 54), (1, 54)], now: now)
        let steady = UsagePace.evaluate(window: steadyWindow, context: .session, now: now, trail: steps)
        Harness.expect(steady?.isIdle == false, "stillness between slow steps is not a pause")

        // The weekly window has no session trail semantics.
        let weekly = UsagePace.evaluate(
            window: UsageWindow(usedPercent: 60, resetsAt: window.resetsAt, windowSeconds: 300 * 60),
            context: .weekly,
            now: now,
            trail: still
        )
        Harness.expect(weekly?.isIdle == false, "only sessions read the trail")
    }

    private static func recentSession() {
        let now = Self.midnight
        // 40% in two hours, half of it in the last 35 minutes: the burst is speeding up. The
        // average alone would land exactly on the reset; the recent rate runs dry first.
        let window = Self.sessionWindow(used: 40, elapsedMinutes: 120, now: now)
        let readings = Self.trail(window, [(35, 20), (5, 40)], now: now)
        let pace = UsagePace.evaluate(window: window, context: .session, now: now, trail: readings)
        let recent = 20.0 / (35 * 60)
        let average = 40.0 / (120 * 60)
        let rate = 0.65 * recent + 0.35 * average
        let remaining = 180.0 * 60
        Harness.expect(pace?.isIdle == false, "a moving session is not paused")
        Harness.expectClose(pace?.etaSeconds, 60 / rate, "the ETA blends recent and average rates", tolerance: 1e-6)
        Harness.expectClose(pace?.speedMultiplierToReset, 60 / (rate * remaining),
                            "headroom uses the same blended rate", tolerance: 1e-9)

        // An anchor older than an hour describes an earlier burst, not this one.
        let stale = Self.trail(window, [(90, 0), (5, 40)], now: now)
        let fallback = UsagePace.evaluate(window: window, context: .session, now: now, trail: stale)
        Harness.expectEqual(fallback?.willLastToReset, true, "a stale anchor falls back to the average rate")
    }

    /// Active 09:00–21:00 UTC, idle otherwise.
    private static var dayShift: DailyUsageRhythm {
        DailyUsageRhythm(hourlyWeights: (0..<24).map { (9..<21).contains($0) ? 1 : 0 }, timeZone: Self.utc)!
    }

    private static func rhythmArithmetic() {
        let rhythm = Self.dayShift
        let hour: TimeInterval = 3600
        Harness.expectClose(rhythm.activeSeconds(from: Self.midnight, to: Self.midnight.addingTimeInterval(24 * hour)),
                            24 * hour, "a whole day counts as a whole day")
        Harness.expectClose(rhythm.activeSeconds(from: Self.midnight.addingTimeInterval(21 * hour),
                                                 to: Self.midnight.addingTimeInterval(33 * hour)),
                            0, "the idle night counts for nothing")
        // From 20:00, an hour of daylight gives two active hours; the third waits for 09:00.
        let empty = rhythm.date(
            after: Self.midnight.addingTimeInterval(20 * hour),
            activeSeconds: 3 * hour,
            limit: Self.midnight.addingTimeInterval(48 * hour)
        )
        Harness.expectEqual(empty, Self.midnight.addingTimeInterval(33.5 * hour), "the walk skips the idle night")
        Harness.expect(
            rhythm.date(after: Self.midnight, activeSeconds: 100 * hour, limit: Self.midnight.addingTimeInterval(24 * hour)) == nil,
            "a walk past the limit has no date"
        )
    }

    private static func rhythmLearning() {
        let resetsAt = Self.midnight.addingTimeInterval(7 * 86_400)
        func records(days: Int) -> [UsageHistoryRecord] {
            var used = 0.0
            return stride(from: 0.0, through: Double(days) * 86_400, by: 1800).map { offset in
                let hour = Int(offset / 3600) % 24
                // The half hour ending here was spent working if it ended inside 09:00–21:00.
                if offset > 0, (10...21).contains(hour) || (hour == 9 && offset.truncatingRemainder(dividingBy: 3600) > 0) {
                    used += 0.4
                }
                return UsageHistoryRecord(
                    provider: .codex,
                    sampledAt: Self.midnight.addingTimeInterval(offset),
                    usedPercent: used,
                    resetsAt: resetsAt,
                    windowMinutes: 10_080
                )
            }
        }

        Harness.expect(DailyUsageRhythm.learn(from: records(days: 1), timeZone: Self.utc) == nil,
                       "one day is not enough to learn a rhythm")
        guard let rhythm = DailyUsageRhythm.learn(from: records(days: 4), timeZone: Self.utc) else {
            Harness.expect(false, "four sampled days should yield a rhythm")
            return
        }
        Harness.expectClose(rhythm.hourlyWeights.reduce(0, +) / 24, 1, "rhythm weights average to one", tolerance: 1e-9)
        Harness.expect(rhythm.hourlyWeights[14] > 3 * rhythm.hourlyWeights[3], "working hours outweigh the night")
        Harness.expect(rhythm.hourlyWeights[3] > 0, "no hour counts for nothing")

        // Rises across a long gap cannot be placed in time, so they teach nothing. One dense day
        // has enough usage but too little exposure; three more days of rising four-hour gaps
        // would push it over if they counted.
        let dense = records(days: 1)
        var used = dense.last!.usedPercent
        let sparse = stride(from: 86_400.0 + 4 * 3600, through: 4 * 86_400, by: 4 * 3600).map { offset in
            used += 2
            return UsageHistoryRecord(
                provider: .codex,
                sampledAt: Self.midnight.addingTimeInterval(offset),
                usedPercent: used,
                resetsAt: resetsAt,
                windowMinutes: 10_080
            )
        }
        Harness.expect(DailyUsageRhythm.learn(from: dense + sparse, timeZone: Self.utc) == nil,
                       "rising four-hour gaps do not count as exposure")

        let dataset = UsageHistoryStore.buildDataset(from: records(days: 4), timeZone: Self.utc)
        Harness.expect(dataset?.weeks.isEmpty == true && dataset?.rhythm != nil,
                       "the rhythm is available before any week completes")
    }

    private static func weeklyRhythm() {
        let hour: TimeInterval = 3600
        let resetsAt = Self.midnight.addingTimeInterval(7 * 86_400)
        let rhythm = Self.dayShift
        func pace(used: Double, at offset: TimeInterval) -> UsagePace? {
            UsagePace.evaluate(
                window: UsageWindow(usedPercent: used, resetsAt: resetsAt, windowSeconds: 604_800),
                context: .weekly,
                now: Self.midnight.addingTimeInterval(offset),
                rhythm: rhythm
            )
        }

        // Nothing is expected to be spent overnight, so the marker holds still until morning.
        let evening = pace(used: 30, at: 23 * hour)
        let morning = pace(used: 30, at: 32 * hour)
        Harness.expectClose(evening?.expectedUsedPercent, 100.0 / 7, "one working day is a seventh of the week",
                            tolerance: 1e-9)
        Harness.expectClose(morning?.expectedUsedPercent, evening?.expectedUsedPercent ?? -1,
                            "the expectation does not move overnight", tolerance: 1e-9)

        // 30% in one working day leaves 70%, which is 2⅓ working days: Tue, Wed, and four hours
        // of Thursday. From Tuesday 08:00 that is Thursday 13:00.
        Harness.expectClose(morning?.etaSeconds, 53 * hour, "the ETA skips idle nights", tolerance: 1e-6)

        // Sessions keep the plain clock.
        let session = UsagePace.evaluate(
            window: UsageWindow(usedPercent: 30, resetsAt: Self.midnight.addingTimeInterval(4 * hour), windowSeconds: 18_000),
            context: .session,
            now: Self.midnight.addingTimeInterval(1 * hour),
            rhythm: rhythm
        )
        // Two of five hours have passed, all of them in the idle night.
        Harness.expectClose(session?.expectedUsedPercent, 40, "a session ignores the daily rhythm", tolerance: 1e-9)
    }
}
