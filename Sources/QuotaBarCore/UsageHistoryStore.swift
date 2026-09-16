// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBar/HistoricalUsagePace.swift (the HistoricalUsageHistoryStore half).
// Kept: the sampling gate, retention, week grouping, completeness test, and curve
// reconstruction. Dropped: backfill from other sources, multi-account scoping.

import Foundation

/// One observation of a rate-limit window.
public struct UsageHistoryRecord: Codable, Sendable {
    public let provider: Provider
    public let sampledAt: Date
    public let usedPercent: Double
    public let resetsAt: Date
    public let windowMinutes: Int

    public init(
        provider: Provider,
        sampledAt: Date,
        usedPercent: Double,
        resetsAt: Date,
        windowMinutes: Int
    ) {
        self.provider = provider
        self.sampledAt = sampledAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

/// A completed window, reduced to a cumulative-usage curve on a fixed grid so weeks of
/// different lengths and sample counts can be compared point by point.
public struct UsageWeekProfile: Sendable, Equatable {
    public static let gridPointCount = 169

    public let resetsAt: Date
    public let windowMinutes: Int
    /// Cumulative used-percent at 169 evenly spaced points from window start to reset.
    public let curve: [Double]

    public init(resetsAt: Date, windowMinutes: Int, curve: [Double]) {
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.curve = curve
    }
}

public struct UsageHistoryDataset: Sendable, Equatable {
    public let weeks: [UsageWeekProfile]

    public init(weeks: [UsageWeekProfile]) {
        self.weeks = weeks
    }
}

/// Persists window samples and turns completed windows into comparable curves.
public actor UsageHistoryStore {
    /// Sample at most this often unless usage moved materially.
    private static let writeInterval: TimeInterval = 30 * 60
    private static let writeDeltaThreshold: Double = 1
    private static let retention: TimeInterval = 56 * 24 * 60 * 60
    /// A window with fewer samples than this cannot describe a shape.
    private static let minimumWeekSamples = 6
    /// A window only counts as complete if it was observed near both ends.
    private static let boundaryCoverage: TimeInterval = 24 * 60 * 60
    /// Reset timestamps drift by seconds between responses; bucket them so one window does not
    /// split into several.
    private static let resetBucket: TimeInterval = 5 * 60

    private let fileURL: URL
    private var records: [UsageHistoryRecord] = []
    private var loaded = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    /// `~/Library/Application Support/QuotaBar/usage-history.json`.
    public static var defaultFileURL: URL {
        PricingOverlayStore.applicationSupportDirectory.appendingPathComponent("usage-history.json")
    }

    /// Records a sample when it is worth keeping, then returns the dataset of completed windows.
    @discardableResult
    public func record(
        provider: Provider,
        window: UsageWindow,
        sampledAt: Date = Date()
    ) -> UsageHistoryDataset? {
        self.ensureLoaded()
        guard let rawResetsAt = window.resetsAt else { return self.dataset(for: provider) }
        let minutes = window.windowSeconds.map { $0 / 60 } ?? UsagePace.Context.weekly.defaultWindowMinutes
        guard minutes > 0 else { return self.dataset(for: provider) }

        let sample = UsageHistoryRecord(
            provider: provider,
            sampledAt: sampledAt,
            usedPercent: min(max(window.usedPercent, 0), 100),
            resetsAt: Self.normalizeReset(rawResetsAt),
            windowMinutes: minutes
        )

        if Self.shouldWrite(sample, after: self.latest(for: provider, resetsAt: sample.resetsAt)) {
            self.records.append(sample)
            self.prune(now: sampledAt)
            self.write()
        }

        return self.dataset(for: provider)
    }

    public func dataset(for provider: Provider) -> UsageHistoryDataset? {
        self.ensureLoaded()
        return Self.buildDataset(from: self.records.filter { $0.provider == provider })
    }

    // MARK: - Sampling gate

    private func latest(for provider: Provider, resetsAt: Date) -> UsageHistoryRecord? {
        self.records
            .filter { $0.provider == provider && $0.resetsAt == resetsAt }
            .max { $0.sampledAt < $1.sampledAt }
    }

    /// Write on a cadence, or sooner if usage moved by a whole point. Sampling every refresh
    /// would bloat the file without sharpening the curve.
    public static func shouldWrite(_ sample: UsageHistoryRecord, after prior: UsageHistoryRecord?) -> Bool {
        guard let prior else { return true }
        if sample.sampledAt.timeIntervalSince(prior.sampledAt) >= Self.writeInterval { return true }
        return abs(sample.usedPercent - prior.usedPercent) >= Self.writeDeltaThreshold
    }

    // MARK: - Dataset construction

    public static func buildDataset(from records: [UsageHistoryRecord]) -> UsageHistoryDataset? {
        guard !records.isEmpty else { return nil }

        struct WeekKey: Hashable {
            let resetsAt: Date
            let windowMinutes: Int
        }

        let grouped = Dictionary(grouping: records) {
            WeekKey(resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes)
        }

        var weeks: [UsageWeekProfile] = []
        for (key, samples) in grouped {
            let duration = TimeInterval(key.windowMinutes) * 60
            guard duration > 0 else { continue }
            let windowStart = key.resetsAt.addingTimeInterval(-duration)
            guard Self.isComplete(samples: samples, windowStart: windowStart, resetsAt: key.resetsAt),
                  let curve = Self.reconstructCurve(
                      samples: samples,
                      windowStart: windowStart,
                      duration: duration
                  ) else { continue }

            weeks.append(UsageWeekProfile(
                resetsAt: key.resetsAt,
                windowMinutes: key.windowMinutes,
                curve: curve
            ))
        }

        guard !weeks.isEmpty else { return nil }
        weeks.sort { $0.resetsAt < $1.resetsAt }
        return UsageHistoryDataset(weeks: weeks)
    }

    /// A window counts only if it was watched near both ends; a week first seen on day five
    /// would otherwise look like a week of very light use.
    public static func isComplete(samples: [UsageHistoryRecord], windowStart: Date, resetsAt: Date) -> Bool {
        guard samples.count >= Self.minimumWeekSamples else { return false }
        let startBoundary = windowStart.addingTimeInterval(Self.boundaryCoverage)
        let endBoundary = resetsAt.addingTimeInterval(-Self.boundaryCoverage)
        let hasStart = samples.contains { $0.sampledAt >= windowStart && $0.sampledAt <= startBoundary }
        let hasEnd = samples.contains { $0.sampledAt >= endBoundary && $0.sampledAt <= resetsAt }
        return hasStart && hasEnd
    }

    /// Samples become a monotone cumulative curve, anchored at zero on the window start and at
    /// the final observation on the reset, then linearly resampled onto the fixed grid.
    public static func reconstructCurve(
        samples: [UsageHistoryRecord],
        windowStart: Date,
        duration: TimeInterval,
        gridPointCount: Int = UsageWeekProfile.gridPointCount
    ) -> [Double]? {
        guard gridPointCount >= 2, !samples.isEmpty else { return nil }

        var points = samples.map { sample -> (u: Double, value: Double) in
            let offset = sample.sampledAt.timeIntervalSince(windowStart)
            return (
                u: min(max(offset / duration, 0), 1),
                value: min(max(sample.usedPercent, 0), 100)
            )
        }
        let endValue = points.map(\.value).max() ?? 0
        points.append((u: 0, value: 0))
        points.append((u: 1, value: endValue))
        points.sort { $0.u == $1.u ? $0.value < $1.value : $0.u < $1.u }

        // Cumulative usage never decreases; a dip means a stale or reordered reading.
        var monotone = points
        var runningMax = 0.0
        for index in monotone.indices {
            runningMax = max(runningMax, monotone[index].value)
            monotone[index].value = runningMax
        }

        var curve = Array(repeating: 0.0, count: gridPointCount)
        let denominator = Double(gridPointCount - 1)
        let first = monotone[0]
        let last = monotone[monotone.count - 1]
        var upperIndex = 1

        for index in 0..<gridPointCount {
            let u = Double(index) / denominator
            if u <= first.u { curve[index] = first.value; continue }
            if u >= last.u { curve[index] = last.value; continue }

            while upperIndex < monotone.count, monotone[upperIndex].u < u { upperIndex += 1 }
            let high = monotone[min(upperIndex, monotone.count - 1)]
            let low = monotone[max(0, upperIndex - 1)]
            if high.u <= low.u {
                curve[index] = max(low.value, high.value)
                continue
            }
            let ratio = (u - low.u) / (high.u - low.u)
            curve[index] = low.value + (high.value - low.value) * ratio
        }
        return curve
    }

    public static func normalizeReset(_ value: Date) -> Date {
        let bucket = Self.resetBucket
        guard bucket > 0 else { return value }
        let rounded = (value.timeIntervalSinceReferenceDate / bucket).rounded() * bucket
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !self.loaded else { return }
        self.loaded = true
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([UsageHistoryRecord].self, from: data) {
            self.records = decoded
        }
        self.prune(now: Date())
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        self.records.removeAll { $0.sampledAt < cutoff }
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(self.records) else { return }
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: self.fileURL, options: .atomic)
    }
}
