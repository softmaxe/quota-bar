import Foundation

/// The last couple of hours of readings of one quota window, held in memory. The average since
/// the reset cannot tell a burst that has stopped from one still running; recent readings can.
public struct UsageTrail: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let sampledAt: Date
        public let usedPercent: Double
        public let resetsAt: Date

        public init(sampledAt: Date, usedPercent: Double, resetsAt: Date) {
            self.sampledAt = sampledAt
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    /// Long enough to hold a recency span and an idle stretch at the slowest refresh cadence.
    static let horizon: TimeInterval = 2 * 3600

    public private(set) var readings: [Reading] = []

    public init(readings: [Reading] = []) {
        self.readings = readings.sorted { $0.sampledAt < $1.sampledAt }
    }

    /// Adds a reading. A new reset starts a new window, so readings of the old one are dropped.
    public mutating func append(_ window: UsageWindow, at sampledAt: Date) {
        guard let rawResetsAt = window.resetsAt else { return }
        let reading = Reading(
            sampledAt: sampledAt,
            usedPercent: min(max(window.usedPercent, 0), 100),
            resetsAt: UsageHistoryStore.normalizeReset(rawResetsAt)
        )
        if let last = self.readings.last {
            guard sampledAt > last.sampledAt else { return }
            if last.resetsAt != reading.resetsAt { self.readings.removeAll() }
        }
        self.readings.append(reading)
        let cutoff = sampledAt.addingTimeInterval(-Self.horizon)
        self.readings.removeAll { $0.sampledAt < cutoff }
    }

    /// Readings of the window that resets at `resetsAt`, up to `now`.
    func readings(resetsAt: Date, now: Date) -> [Reading] {
        let normalized = UsageHistoryStore.normalizeReset(resetsAt)
        return self.readings.filter { $0.resetsAt == normalized && $0.sampledAt <= now }
    }
}
