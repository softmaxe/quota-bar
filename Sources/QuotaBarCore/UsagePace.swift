// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/UsagePace.swift and Sources/CodexBar/UsagePaceText.swift.
// Kept: the linear expected-usage model, the stage thresholds, the ETA projection, and the
// deficit/reserve labelling. Dropped: workday-weighted progress and the run-out risk percentage.
// Added: a learned daily rhythm for weekly windows, and recency and idle handling for sessions.

import Foundation

public struct UsagePace: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case onTrack
        /// Ahead means burning the window faster than the clock: a deficit.
        case slightlyAhead
        case ahead
        case farAhead
        /// Behind means using less than the clock allows: a reserve.
        case slightlyBehind
        case behind
        case farBehind

        public var isAhead: Bool {
            switch self {
            case .slightlyAhead, .ahead, .farAhead: true
            default: false
            }
        }
    }

    public let stage: Stage
    /// Actual minus expected usage, in percentage points. Positive is a deficit.
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    /// Seconds until the window is projected to empty, if it empties before the reset.
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool
    /// The window is valid, but elapsed time and actual usage are both too small to project a rate.
    public let isWarmingUp: Bool
    /// Set while a session has stopped moving but would still run dry at its earlier pace. The
    /// clock is no longer spending the budget, so this is how much working time is left rather
    /// than a moment it empties.
    public let activeTimeLeftSeconds: TimeInterval?

    public var isIdle: Bool { self.activeTimeLeftSeconds != nil }

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        isWarmingUp: Bool = false,
        activeTimeLeftSeconds: TimeInterval? = nil
    ) {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.isWarmingUp = isWarmingUp
        self.activeTimeLeftSeconds = activeTimeLeftSeconds
    }

    /// Built from the historical model, where expected usage comes from past weeks rather than
    /// from the clock. The stage is derived the same way.
    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool
    ) -> UsagePace {
        let delta = actualUsedPercent - expectedUsedPercent
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expectedUsedPercent,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset
        )
    }

    /// Where the fill "should" sit on a bar that shows remaining budget.
    public var expectedRemainingPercent: Double {
        100 - self.expectedUsedPercent
    }

    /// Sessions blend the rate over this span with the average since the reset.
    static let recentSpan: TimeInterval = 30 * 60
    /// A recent reading older than this no longer describes the current burst.
    static let recentSpanLimit: TimeInterval = 60 * 60
    static let recentWeight = 0.65
    /// A session that has not moved for this long is treated as paused.
    static let idleThreshold: TimeInterval = 10 * 60
    /// A slow session moves in whole-point steps, so a pause must also outlast two of them.
    static let idleSteps = 2.0

    /// nil for unavailable, expired, inconsistent, or exhausted windows. Fresh windows retain
    /// their expected usage while rate projections wait for enough elapsed time or consumption.
    ///
    /// `trail` sharpens a session's rate with its recent readings and spots a pause. `rhythm`
    /// measures a weekly window in active hours rather than clock hours.
    public static func evaluate(
        window: UsageWindow,
        context: QuotaWindowKind,
        now: Date = Date(),
        trail: UsageTrail? = nil,
        rhythm: DailyUsageRhythm? = nil
    ) -> UsagePace? {
        guard let resetsAt = window.resetsAt else { return nil }
        guard window.remainingPercent > 0 else { return nil }

        let minutes = window.windowSeconds.map { $0 / 60 } ?? context.defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        // A reset in the past, or further out than one whole window, means the window data and
        // the clock disagree; no honest pace can be derived from that.
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = min(max(duration - timeUntilReset, 0), duration)
        let actual = min(max(window.usedPercent, 0), 100)
        // Usage recorded before any time elapsed is a stale reading, not a pace.
        if elapsed == 0, actual > 0 { return nil }

        // Time is measured in active seconds: plain seconds, unless a weekly window has a
        // learned rhythm that discounts the hours its user is usually away.
        let rhythm = context == .weekly ? rhythm : nil
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let activeElapsed = rhythm?.activeSeconds(from: windowStart, to: now) ?? elapsed
        let activeTotal = rhythm?.activeSeconds(from: windowStart, to: resetsAt) ?? duration
        guard activeTotal > 0 else { return nil }
        let activeRemaining = max(0, activeTotal - activeElapsed)

        let expected = min(max((activeElapsed / activeTotal) * 100, 0), 100)
        // Avoid projecting tiny, rounded readings just after reset. Meaningful consumption can
        // establish a rate sooner than the clock alone, especially in a week-long window.
        if expected < 3, actual < 3 {
            return UsagePace(
                stage: Self.stage(for: actual - expected),
                deltaPercent: actual - expected,
                expectedUsedPercent: expected,
                etaSeconds: nil,
                willLastToReset: false,
                isWarmingUp: true
            )
        }

        let delta = actual - expected
        let left = 100 - actual
        let averageRate = activeElapsed > 0 ? actual / activeElapsed : 0
        var rate = averageRate
        var activeTimeLeft: TimeInterval?

        if context == .session, let trail, averageRate > 0 {
            let readings = trail.readings(resetsAt: resetsAt, now: now)
            if let pausedRate = Self.pausedRate(readings: readings, actual: actual, averageRate: averageRate),
               left / pausedRate < activeRemaining {
                // Resuming at the earlier pace would still run dry, so the honest answer is how
                // much working time is left, not a clock time that keeps sliding while paused.
                rate = pausedRate
                activeTimeLeft = left / pausedRate
            } else if let recent = Self.recentRate(readings: readings, actual: actual, now: now) {
                rate = Self.recentWeight * recent + (1 - Self.recentWeight) * averageRate
            }
        }

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if actual >= 100 {
            etaSeconds = 0
        } else if activeTimeLeft != nil {
            // Paused: neither a run-out moment nor a promise to last.
        } else if rate > 0 {
            let needed = left / rate
            if needed >= activeRemaining {
                willLastToReset = true
            } else if let rhythm {
                if let empty = rhythm.date(after: now, activeSeconds: needed, limit: resetsAt) {
                    etaSeconds = empty.timeIntervalSince(now)
                } else {
                    willLastToReset = true
                }
            } else {
                etaSeconds = needed
            }
        } else if elapsed > 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            activeTimeLeftSeconds: activeTimeLeft
        )
    }

    /// The pace a session was running at before it went still, or nil if it has not held still
    /// long enough to call it paused. Only observed stillness counts: a single old reading says
    /// nothing about the time since.
    ///
    /// A slow session moves in whole-point steps, so the stillness has to outlast two steps at
    /// the slower of the pre-pause and average rates. Otherwise steady light use, with a reading
    /// that holds between steps, would flip in and out of "paused".
    static func pausedRate(readings: [UsageTrail.Reading], actual: Double, averageRate: Double) -> Double? {
        guard let latest = readings.last, abs(latest.usedPercent - actual) < 1e-9 else { return nil }
        var stillIndex = readings.count - 1
        while stillIndex > 0, abs(readings[stillIndex - 1].usedPercent - actual) < 1e-9 {
            stillIndex -= 1
        }
        let stillSince = readings[stillIndex].sampledAt

        var beforeRate: Double?
        if stillIndex > 0, let first = readings.first {
            let span = stillSince.timeIntervalSince(first.sampledAt)
            if span > 0 { beforeRate = max(0, actual - first.usedPercent) / span }
        }
        let slowest = min(averageRate, beforeRate ?? averageRate)
        guard slowest > 0 else { return nil }
        let threshold = max(Self.idleThreshold, Self.idleSteps / slowest)
        guard latest.sampledAt.timeIntervalSince(stillSince) >= threshold else { return nil }
        return beforeRate.map { Self.recentWeight * $0 + (1 - Self.recentWeight) * averageRate } ?? averageRate
    }

    /// Points per second since the newest reading at least `recentSpan` old, if one is recent
    /// enough to describe the current burst.
    static func recentRate(readings: [UsageTrail.Reading], actual: Double, now: Date) -> Double? {
        guard let anchor = readings.last(where: { now.timeIntervalSince($0.sampledAt) >= Self.recentSpan }) else {
            return nil
        }
        let span = now.timeIntervalSince(anchor.sampledAt)
        guard span <= Self.recentSpanLimit else { return nil }
        return max(0, actual - anchor.usedPercent) / span
    }

    public static func stage(for delta: Double) -> Stage {
        let magnitude = abs(delta)
        if magnitude <= 2 { return .onTrack }
        if magnitude <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if magnitude <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    // MARK: - Labels

    /// How far off pace the window is: "On pace", "4% in deficit", "8% in reserve".
    public var deltaLabel: String {
        let value = Int(abs(self.deltaPercent).rounded())
        if value == 0 || self.stage == .onTrack { return "On pace" }
        return self.stage.isAhead ? "\(value)% in deficit" : "\(value)% in reserve"
    }
}
