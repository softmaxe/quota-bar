// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/UsagePace.swift and Sources/CodexBar/UsagePaceText.swift.
// Kept: the linear expected-usage model, the stage thresholds, the ETA projection, and the
// deficit/reserve labelling. Dropped: workday-weighted progress and the run-out risk percentage.

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
    public let actualUsedPercent: Double
    /// Seconds until the window is projected to empty, if it empties before the reset.
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool
    /// How much faster than the current rate the remaining budget allows.
    public let speedMultiplierToReset: Double?
    /// Share of comparable past weeks that ran the window dry. Only the historical model
    /// produces this, and only once enough weeks have been recorded.
    public let runOutProbability: Double?
    /// The window is valid, but too little time has elapsed to project its consumption rate.
    public let isWarmingUp: Bool

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        speedMultiplierToReset: Double?,
        runOutProbability: Double? = nil,
        isWarmingUp: Bool = false
    ) {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.speedMultiplierToReset = speedMultiplierToReset
        self.runOutProbability = runOutProbability
        self.isWarmingUp = isWarmingUp
    }

    /// Built from the historical model, where expected usage comes from past weeks rather than
    /// from the clock. The stage and the headroom multiplier are derived the same way.
    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double?,
        projectedRemainingUsage: Double
    ) -> UsagePace {
        let delta = actualUsedPercent - expectedUsedPercent
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expectedUsedPercent,
            actualUsedPercent: actualUsedPercent,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            speedMultiplierToReset: Self.speedMultiplier(
                remainingCapacity: 100 - actualUsedPercent,
                projectedRemainingUsage: projectedRemainingUsage
            ),
            runOutProbability: runOutProbability
        )
    }

    /// Where the fill "should" sit on a bar that shows remaining budget.
    public var expectedRemainingPercent: Double {
        100 - self.expectedUsedPercent
    }

    /// Which window a pace line describes; only the ETA wording differs.
    public enum Context: Sendable {
        case session
        case weekly

        public var defaultWindowMinutes: Int {
            switch self {
            case .session: 300
            case .weekly: 10_080
            }
        }
    }

    /// nil for unavailable, expired, inconsistent, or exhausted windows. Fresh windows retain
    /// their expected usage while rate projections wait for enough elapsed time.
    public static func evaluate(
        window: UsageWindow,
        context: Context,
        now: Date = Date()
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
        let expected = min(max((elapsed / duration) * 100, 0), 100)
        let actual = min(max(window.usedPercent, 0), 100)
        // Usage recorded before any time elapsed is a stale reading, not a pace.
        if elapsed == 0, actual > 0 { return nil }
        // Keep the pace visible after a reset without extrapolating rounded usage into an ETA.
        if expected < 3 {
            return UsagePace(
                stage: Self.stage(for: actual - expected),
                deltaPercent: actual - expected,
                expectedUsedPercent: expected,
                actualUsedPercent: actual,
                etaSeconds: nil,
                willLastToReset: false,
                speedMultiplierToReset: nil,
                isWarmingUp: true
            )
        }

        let delta = actual - expected
        var etaSeconds: TimeInterval?
        var willLastToReset = false

        let projectedRemainingUsage = elapsed > 0 ? actual * timeUntilReset / elapsed : 0
        let speedMultiplier = Self.speedMultiplier(
            remainingCapacity: 100 - actual,
            projectedRemainingUsage: projectedRemainingUsage
        )

        if actual >= 100 {
            etaSeconds = 0
        } else if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let candidate = (100 - actual) / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            speedMultiplierToReset: speedMultiplier,
            runOutProbability: nil
        )
    }

    public static func stage(for delta: Double) -> Stage {
        let magnitude = abs(delta)
        if magnitude <= 2 { return .onTrack }
        if magnitude <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if magnitude <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    private static func speedMultiplier(
        remainingCapacity: Double,
        projectedRemainingUsage: Double
    ) -> Double? {
        guard remainingCapacity > 0, projectedRemainingUsage > 0 else { return nil }
        let multiplier = remainingCapacity / projectedRemainingUsage
        return multiplier.isFinite ? multiplier : nil
    }

    // MARK: - Labels

    /// Left half of the pace line: "On pace", "4% in deficit", "8% in reserve".
    public var deltaLabel: String {
        let value = Int(abs(self.deltaPercent).rounded())
        if value == 0 || self.stage == .onTrack { return "On pace" }
        return self.stage.isAhead ? "\(value)% in deficit" : "\(value)% in reserve"
    }

    /// Right half: whether the budget survives to the reset, or when it is projected to empty.
    /// `durationText` renders a seconds value the way the reset countdowns do.
    public func etaLabel(context: Context, durationText: (TimeInterval) -> String) -> String? {
        if self.isWarmingUp { return "Estimating usage pace…" }
        let base: String?
        if self.willLastToReset {
            if self.deltaPercent < -15, let multiplier = self.speedMultiplierToReset, multiplier >= 1.5 {
                base = "Lasts until reset · 1.5× headroom"
            } else {
                base = "Lasts until reset"
            }
        } else if let etaSeconds {
            let text = durationText(etaSeconds)
            switch context {
            case .session:
                base = etaSeconds <= 0 ? "Projected empty now" : "Projected empty in \(text)"
            case .weekly:
                base = etaSeconds <= 0 ? "Runs out now" : "Runs out in \(text)"
            }
        } else {
            base = nil
        }

        guard let runOutProbability else { return base }
        // Rounded to the nearest 5 so it reads as an estimate, not a measurement.
        let risk = Int((min(1, max(0, runOutProbability)) * 100 / 5).rounded() * 5)
        guard let base else { return "(\(risk)% risk)" }
        return "\(base) (\(risk)% risk)"
    }
}
