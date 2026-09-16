// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBar/HistoricalUsagePace.swift (CodexHistoricalPaceEvaluator).
//
// The linear model assumes budget should be spent evenly against the clock. Real weeks are not
// even, so once enough complete windows have been recorded this model derives the expected
// curve from them instead, and projects the run-out date by replaying each past week from the
// current position.

import Foundation

public enum HistoricalUsagePace {
    /// Below this the weighted median is noise, so the linear model stays in charge.
    public static let minimumWeeks = 3
    /// Risk needs more evidence than the expected curve does.
    static let minimumWeeksForRisk = 5
    /// Older weeks fade with a three-week time constant.
    static let recencyTauWeeks: Double = 3
    static let epsilon: Double = 1e-9

    /// nil whenever the historical model cannot speak: the caller then falls back to linear.
    public static func evaluate(
        window: UsageWindow,
        dataset: UsageHistoryDataset?,
        now: Date = Date()
    ) -> UsagePace? {
        guard let dataset, let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowSeconds.map { $0 / 60 } ?? UsagePace.Context.weekly.defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let normalizedResetsAt = UsageHistoryStore.normalizeReset(resetsAt)
        let elapsed = Self.clamp(duration - timeUntilReset, 0, duration)
        let actual = Self.clamp(window.usedPercent, 0, 100)
        if elapsed == 0, actual > 0 { return nil }
        let uNow = Self.clamp(elapsed / duration, 0, 1)

        // Only past windows of the same length inform this one.
        let weeks = dataset.weeks.filter {
            $0.windowMinutes == minutes && $0.resetsAt < normalizedResetsAt
        }
        guard weeks.count >= Self.minimumWeeks else { return nil }

        let weighted = weeks.map { week -> (week: UsageWeekProfile, weight: Double) in
            let ageWeeks = max(0, normalizedResetsAt.timeIntervalSince(week.resetsAt) / duration)
            return (week, exp(-ageWeeks / Self.recencyTauWeeks))
        }
        let totalWeight = weighted.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > Self.epsilon else { return nil }

        // Effective sample size drives how far the expected curve leans on history rather than
        // on the straight line: few, or heavily skewed, weeks keep it near linear.
        let totalWeightSquared = weighted.reduce(0.0) { $0 + ($1.weight * $1.weight) }
        let nEff = totalWeightSquared > Self.epsilon ? (totalWeight * totalWeight) / totalWeightSquared : 0
        let lambda = Self.clamp((nEff - 2) / 6, 0, 1)

        let gridCount = UsageWeekProfile.gridPointCount
        let denominator = Double(gridCount - 1)
        var expectedCurve = Array(repeating: 0.0, count: gridCount)
        // Reuse the median's pair storage rather than allocating a values array at every point.
        var medianPairs = Array(repeating: (value: 0.0, weight: 0.0), count: weighted.count)
        for index in 0..<gridCount {
            let u = Double(index) / denominator
            for pairIndex in weighted.indices {
                medianPairs[pairIndex] = (
                    value: weighted[pairIndex].week.curve[index],
                    weight: weighted[pairIndex].weight
                )
            }
            let median = Self.weightedMedian(pairs: &medianPairs)
            let linear = 100 * u
            // Past demand can exceed what the quota sustains. Blending toward it is fine, but
            // capping at the linear baseline stops a heavy history from reporting a reserve.
            expectedCurve[index] = Self.clamp((lambda * median) + ((1 - lambda) * linear), 0, linear)
        }

        var runningExpected = 0.0
        for index in expectedCurve.indices {
            runningExpected = max(runningExpected, expectedCurve[index])
            expectedCurve[index] = runningExpected
        }

        let expectedNow = Self.interpolate(curve: expectedCurve, at: uNow)

        // Replay each past week from where this one stands: shift its curve so it meets the
        // current usage, and see whether the shifted curve reaches the cap before the reset.
        var runOutMass = 0.0
        var crossings: [(eta: TimeInterval, weight: Double)] = []
        for entry in weighted {
            let extended = Self.extendPastCap(entry.week.curve)
            let weekNow = Self.interpolate(curve: extended, at: uNow)
            let shift = actual - weekNow
            guard (extended.last ?? 0) + shift >= 100 - Self.epsilon else { continue }

            runOutMass += entry.weight
            if let crossing = Self.firstCrossing(
                after: uNow,
                curve: extended,
                shift: shift,
                actualAtNow: actual
            ) {
                crossings.append((max(0, (crossing - uNow) * duration), entry.weight))
            }
        }

        // Laplace-smoothed so a handful of weeks never reports 0% or 100% certainty.
        let probability = Self.clamp((runOutMass + 0.5) / (totalWeight + 1), 0, 1)
        var runOutProbability: Double? = weeks.count >= Self.minimumWeeksForRisk ? probability : nil
        var willLastToReset = probability < 0.5
        var etaSeconds: TimeInterval?

        if actual >= 100 {
            willLastToReset = false
            etaSeconds = 0
            runOutProbability = 1
        } else if !willLastToReset {
            if crossings.isEmpty {
                willLastToReset = true
            } else {
                etaSeconds = max(0, Self.weightedMedian(
                    values: crossings.map(\.eta),
                    weights: crossings.map(\.weight)
                ))
            }
        }

        return UsagePace.historical(
            expectedUsedPercent: expectedNow,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability,
            projectedRemainingUsage: max(0, (expectedCurve.last ?? expectedNow) - expectedNow)
        )
    }

    /// A week that hit the cap stops carrying rate information past that point, so the segment
    /// after the cap is replaced by the average slope that got it there.
    public static func extendPastCap(_ curve: [Double]) -> [Double] {
        var extended = curve
        guard let capIndex = extended.firstIndex(where: { $0 >= 100 - Self.epsilon }),
              capIndex > 0, capIndex < extended.count - 1 else { return extended }

        let denominator = Double(extended.count - 1)
        let uCap = Double(capIndex) / denominator
        let slope = extended[capIndex] / uCap
        for index in capIndex..<extended.count {
            extended[index] = slope * (Double(index) / denominator)
        }
        return extended
    }

    /// Where a shifted curve first reaches the cap, in window fraction.
    public static func firstCrossing(
        after uNow: Double,
        curve: [Double],
        shift: Double,
        actualAtNow: Double
    ) -> Double? {
        let gridCount = curve.count
        guard gridCount >= 2 else { return nil }

        let denominator = Double(gridCount - 1)
        var previousU = uNow
        var previousValue = actualAtNow
        let startIndex = min(gridCount - 1, max(1, Int(floor(uNow * denominator)) + 1))

        for index in startIndex..<gridCount {
            let u = Double(index) / denominator
            if u <= uNow + Self.epsilon { continue }
            let value = Self.clamp(curve[index] + shift, 0, 100)
            if previousValue < 100 - Self.epsilon, value >= 100 - Self.epsilon {
                let delta = value - previousValue
                if abs(delta) <= Self.epsilon { return u }
                let ratio = Self.clamp((100 - previousValue) / delta, 0, 1)
                return Self.clamp(previousU + ratio * (u - previousU), uNow, 1)
            }
            previousU = u
            previousValue = value
        }
        return nil
    }

    public static func interpolate(curve: [Double], at u: Double) -> Double {
        guard !curve.isEmpty else { return 0 }
        if curve.count == 1 { return curve[0] }
        let scaled = Self.clamp(u, 0, 1) * Double(curve.count - 1)
        let lower = Int(floor(scaled))
        let upper = min(curve.count - 1, lower + 1)
        if lower == upper { return curve[lower] }
        return curve[lower] + ((curve[upper] - curve[lower]) * (scaled - Double(lower)))
    }

    public static func weightedMedian(values: [Double], weights: [Double]) -> Double {
        guard values.count == weights.count, !values.isEmpty else { return 0 }
        var pairs = zip(values, weights)
            .map { (value: $0, weight: max(0, $1)) }
        return Self.weightedMedian(pairs: &pairs)
    }

    private static func weightedMedian(pairs: inout [(value: Double, weight: Double)]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        pairs.sort { $0.value < $1.value }
        let totalWeight = pairs.reduce(0.0) { $0 + $1.weight }
        if totalWeight <= Self.epsilon {
            return pairs[pairs.count / 2].value
        }

        let threshold = totalWeight / 2
        var cumulative = 0.0
        for pair in pairs {
            cumulative += pair.weight
            if cumulative >= threshold { return pair.value }
        }
        return pairs.last?.value ?? 0
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
