import Foundation

/// One cooldown per provider. Refreshes are scoped to the provider the status item is showing, so
/// each provider's minute is its own: the one on screen is polled and clicked against its own
/// gate, and the one that is not shown holds whatever is left of its wait until the user switches
/// to it. Switching away and straight back therefore buys no extra fetches.
public struct ProviderRefreshCooldown {
    private var gates: [Provider: RefreshCooldownGate] = [:]
    private let minimumInterval: TimeInterval
    private let tolerance: TimeInterval

    public init(
        minimumInterval: TimeInterval = RefreshCooldownGate.defaultMinimumInterval,
        tolerance: TimeInterval = RefreshCooldownGate.defaultTolerance
    ) {
        self.minimumInterval = minimumInterval
        self.tolerance = tolerance
    }

    /// Claims this provider's cooldown when its own wait has elapsed. Nothing another provider
    /// did can block or unblock it.
    public mutating func claimRefresh(_ provider: Provider, at time: TimeInterval) -> Bool {
        var gate = self.gate(provider)
        defer { self.gates[provider] = gate }
        return gate.claimRefresh(at: time)
    }

    /// Starts this provider's cooldown for a refresh that ran without asking.
    public mutating func recordRefresh(_ provider: Provider, at time: TimeInterval) {
        var gate = self.gate(provider)
        gate.recordRefresh(at: time)
        self.gates[provider] = gate
    }

    /// Seconds left before this provider may be refreshed again; zero when it may right now.
    public func remaining(_ provider: Provider, at time: TimeInterval) -> TimeInterval {
        self.gate(provider).remaining(at: time)
    }

    private func gate(_ provider: Provider) -> RefreshCooldownGate {
        self.gates[provider]
            ?? RefreshCooldownGate(minimumInterval: self.minimumInterval, tolerance: self.tolerance)
    }
}
