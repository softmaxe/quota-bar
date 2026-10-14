import Foundation

/// How a user's consumption spreads across the hours of a local day, learned from recorded
/// window samples. A week-long window spends most of its time asleep or away; measuring pace
/// against active hours instead of the raw clock stops the expectation from racing ahead every
/// night and the projection from spending the budget while nobody is working.
///
/// This needs only a few days of samples, so it covers the weeks before the historical model
/// has enough complete windows to take over.
public struct DailyUsageRhythm: Sendable, Equatable {
    /// Relative activity for each local hour of the day, with a mean of 1. A uniform rhythm
    /// reproduces the plain clock.
    public let hourlyWeights: [Double]
    public let timeZone: TimeZone

    /// Observed time needed before a learned shape is trusted.
    static let minimumExposure: TimeInterval = 48 * 3600
    /// Consumption needed before a learned shape is trusted, in percentage points.
    static let minimumUsage: Double = 5
    /// A rise across a longer gap cannot be placed in time, so that gap is ignored. A flat gap
    /// of any length still says nothing was used, which is how idle nights get learned.
    static let maximumRisingGap: TimeInterval = 3 * 3600
    /// Pseudo-hours of average activity added to every hour, so a sparsely observed hour is
    /// pulled toward the mean instead of being trusted from one reading.
    static let priorHours: Double = 2
    /// Share of the uniform clock mixed back in. No hour ever counts for nothing, so working at
    /// an unusual hour still moves the projection.
    static let uniformFloor: Double = 0.2

    public init?(hourlyWeights: [Double], timeZone: TimeZone = .current) {
        guard hourlyWeights.count == 24, hourlyWeights.allSatisfy({ $0 >= 0 && $0.isFinite }) else {
            return nil
        }
        let mean = hourlyWeights.reduce(0, +) / 24
        guard mean > 0 else { return nil }
        self.hourlyWeights = hourlyWeights.map { $0 / mean }
        self.timeZone = timeZone
    }

    // MARK: - Learning

    /// nil until the samples cover enough time and consumption to describe a day.
    public static func learn(
        from records: [UsageHistoryRecord],
        timeZone: TimeZone = .current
    ) -> DailyUsageRhythm? {
        var usage = Array(repeating: 0.0, count: 24)
        var exposure = Array(repeating: 0.0, count: 24)

        struct WindowKey: Hashable {
            let resetsAt: Date
            let windowMinutes: Int
        }
        let windows = Dictionary(grouping: records) {
            WindowKey(resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes)
        }
        for samples in windows.values {
            let ordered = samples.sorted { $0.sampledAt < $1.sampledAt }
            for (earlier, later) in zip(ordered, ordered.dropFirst()) {
                let gap = later.sampledAt.timeIntervalSince(earlier.sampledAt)
                guard gap > 0 else { continue }
                let rise = max(0, later.usedPercent - earlier.usedPercent)
                if rise > 0, gap > Self.maximumRisingGap { continue }
                Self.forEachHour(from: earlier.sampledAt, to: later.sampledAt, timeZone: timeZone) { hour, seconds in
                    exposure[hour] += seconds
                    // Spread evenly: the samples cannot say when within the gap it was used.
                    usage[hour] += rise * seconds / gap
                }
            }
        }

        let totalExposure = exposure.reduce(0, +)
        let totalUsage = usage.reduce(0, +)
        guard totalExposure >= Self.minimumExposure, totalUsage >= Self.minimumUsage else { return nil }

        let meanRate = totalUsage / totalExposure
        let prior = Self.priorHours * 3600
        let rates = (0..<24).map { hour in
            (usage[hour] + meanRate * prior) / (exposure[hour] + prior)
        }
        let mean = rates.reduce(0, +) / 24
        guard mean > 0 else { return nil }
        let floored = rates.map { (1 - Self.uniformFloor) * ($0 / mean) + Self.uniformFloor }
        return DailyUsageRhythm(hourlyWeights: floored, timeZone: timeZone)
    }

    // MARK: - Active time

    /// Clock time between two dates, weighted by how active each hour usually is.
    public func activeSeconds(from start: Date, to end: Date) -> TimeInterval {
        guard end > start else { return 0 }
        var total = 0.0
        Self.forEachHour(from: start, to: end, timeZone: self.timeZone) { hour, seconds in
            total += self.hourlyWeights[hour] * seconds
        }
        return total
    }

    /// The wall-clock date at which `activeSeconds` of weighted time has passed after `start`,
    /// or nil if that takes longer than `limit`.
    public func date(after start: Date, activeSeconds: TimeInterval, limit: Date) -> Date? {
        guard activeSeconds > 0 else { return start }
        var remaining = activeSeconds
        var result: Date?
        Self.forEachHourSegment(from: start, to: limit, timeZone: self.timeZone) { hour, seconds, segmentStart in
            guard result == nil else { return }
            let weight = self.hourlyWeights[hour]
            let available = weight * seconds
            if available >= remaining, weight > 0 {
                result = segmentStart.addingTimeInterval(remaining / weight)
            } else {
                remaining -= available
            }
        }
        return result
    }

    // MARK: - Hour segments

    private static func forEachHour(
        from start: Date,
        to end: Date,
        timeZone: TimeZone,
        _ body: (_ hour: Int, _ seconds: TimeInterval) -> Void
    ) {
        Self.forEachHourSegment(from: start, to: end, timeZone: timeZone) { hour, seconds, _ in
            body(hour, seconds)
        }
    }

    /// Splits [start, end) at local hour boundaries and reports each piece's hour of day.
    private static func forEachHourSegment(
        from start: Date,
        to end: Date,
        timeZone: TimeZone,
        _ body: (_ hour: Int, _ seconds: TimeInterval, _ segmentStart: Date) -> Void
    ) {
        var cursor = start
        while cursor < end {
            let offset = TimeInterval(timeZone.secondsFromGMT(for: cursor))
            let local = cursor.timeIntervalSinceReferenceDate + offset
            let hourStart = (local / 3600).rounded(.down) * 3600
            let hour = ((Int(hourStart / 3600) % 24) + 24) % 24
            let boundary = Date(timeIntervalSinceReferenceDate: hourStart + 3600 - offset)
            // A daylight-saving jump can put the computed boundary at or before the cursor.
            let next = min(end, boundary > cursor ? boundary : cursor.addingTimeInterval(3600))
            body(hour, next.timeIntervalSince(cursor), cursor)
            cursor = next
        }
    }
}
