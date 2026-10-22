import Foundation

/// What one provider's past readings say about how fast its quota windows are being spent, and
/// the pace that follows for each window.
///
/// Callers hand over each reading and ask for a window's pace; which model answers is decided
/// here. A weekly window is read against completed past weeks once there are enough of them,
/// and otherwise against the clock, measured in the hours its user is usually active. A session
/// is read against the clock, sharpened by its recent readings and by spotting a pause.
public struct QuotaPace: Sendable, Equatable {
    /// Completed weekly windows and the learned daily rhythm, from the history store.
    public private(set) var history: UsageHistoryDataset?
    /// Recent session readings, so the session pace can tell a running burst from a pause.
    public private(set) var sessionTrail: UsageTrail

    public init(history: UsageHistoryDataset? = nil, sessionTrail: UsageTrail = UsageTrail()) {
        self.history = history
        self.sessionTrail = sessionTrail
    }

    /// Takes in a successful reading. `history` is what the history store returned after
    /// recording the reading's weekly window; nil keeps the history already held.
    public mutating func observe(_ snapshot: UsageSnapshot, history: UsageHistoryDataset? = nil) {
        if let history { self.history = history }
        if let session = snapshot.session {
            self.sessionTrail.append(session, at: snapshot.fetchedAt)
        }
    }

    /// The pace of `window`, or nil when it cannot be read: no reset date, an exhausted window,
    /// or a reading the clock contradicts.
    public func pace(for kind: QuotaWindowKind, window: UsageWindow, now: Date = Date()) -> UsagePace? {
        switch kind {
        case .weekly:
            HistoricalUsagePace.evaluate(window: window, dataset: self.history, now: now)
                ?? UsagePace.evaluate(window: window, context: .weekly, now: now, rhythm: self.history?.rhythm)
        case .session:
            UsagePace.evaluate(window: window, context: .session, now: now, trail: self.sessionTrail)
        }
    }
}

extension UsagePace {
    /// The short line under a window's bar: how long the budget lasts, or how far off pace it is
    /// when that cannot be said. `durationText` renders seconds the way the reset countdowns do.
    public func summary(kind: QuotaWindowKind, durationText: (TimeInterval) -> String) -> String {
        if let activeTimeLeftSeconds { return "\(durationText(activeTimeLeftSeconds)) of use left" }
        if self.willLastToReset { return "Lasts until reset" }
        if self.isWarmingUp { return "Estimating usage pace…" }
        guard let etaSeconds else { return self.deltaLabel }
        switch kind {
        case .session:
            return etaSeconds <= 0 ? "Projected empty now" : "Empty in about \(durationText(etaSeconds))"
        case .weekly:
            return etaSeconds <= 0 ? "Runs out now" : "Runs out in \(durationText(etaSeconds))"
        }
    }
}
