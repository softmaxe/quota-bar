import Foundation

/// Whether a provider's quota may be refreshed now, for every path that asks: polling, opening
/// the menu, switching providers, and the Refresh row. The menu's Refresh row is read from the
/// same rules, so what it offers is always what a click would get.
///
/// Each provider waits out its own minute after any refresh of it, so switching back and forth
/// buys no extra fetches. A server 429 holds every path until its retry date. One exception to
/// the local minute: when the last refresh found a credential only the user may repair, a user
/// click goes through at once, still behind any server 429.
public struct RefreshEligibility {
    /// What the last refresh of a provider left behind that bears on the next one.
    public struct Conditions: Equatable {
        public var isRefreshing: Bool
        /// When the server said to retry after a 429.
        public var serverRetryAfter: Date?
        /// The last refresh found a credential that one explicit user action may repair.
        public var allowsCredentialRecovery: Bool
        /// No credentials on this machine, so the row offers to check sign-in again.
        public var isSignedOut: Bool

        public init(
            isRefreshing: Bool = false,
            serverRetryAfter: Date? = nil,
            allowsCredentialRecovery: Bool = false,
            isSignedOut: Bool = false
        ) {
            self.isRefreshing = isRefreshing
            self.serverRetryAfter = serverRetryAfter
            self.allowsCredentialRecovery = allowsCredentialRecovery
            self.isSignedOut = isSignedOut
        }
    }

    /// Who is asking. Only a user may repair a credential, so only a user may skip the minute.
    public enum Trigger: Equatable {
        case automatic
        case user
    }

    /// What the menu's Refresh row says and whether it accepts a click. A row that silently does
    /// nothing reads as broken, so the wait is spelled out on the row itself.
    public struct Row: Equatable {
        public let title: String
        public let trailingText: String?
        public let isEnabled: Bool
        /// The title names work in flight, which the menu shows as working rather than as text.
        public let isInProgress: Bool

        public init(title: String, trailingText: String?, isEnabled: Bool, isInProgress: Bool = false) {
            self.title = title
            self.trailingText = trailingText
            self.isEnabled = isEnabled
            self.isInProgress = isInProgress
        }

        public static let idle = Row(title: "Refresh", trailingText: nil, isEnabled: true)
    }

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

    /// Claims a refresh of `provider` when one may run, starting its minute. `uptime` is a
    /// monotonic clock for the local minute; `now` is the wall clock the server's date is on.
    public mutating func claim(
        _ provider: Provider,
        by trigger: Trigger,
        given conditions: Conditions,
        uptime: TimeInterval,
        now: Date
    ) -> Bool {
        guard !conditions.isRefreshing, Self.serverRemaining(conditions, now: now) == 0 else { return false }
        if trigger == .user, conditions.allowsCredentialRecovery {
            self.recordRefresh(provider, uptime: uptime)
            return true
        }
        var gate = self.gate(provider)
        defer { self.gates[provider] = gate }
        return gate.claimRefresh(at: uptime)
    }

    /// Seconds before an automatic refresh may run: the longer of the local minute and the
    /// server's wait.
    public func remaining(
        _ provider: Provider,
        given conditions: Conditions,
        uptime: TimeInterval,
        now: Date
    ) -> TimeInterval {
        max(self.gate(provider).remaining(at: uptime), Self.serverRemaining(conditions, now: now))
    }

    /// Whether a user click on the Refresh row would start a refresh now.
    public func canRefresh(_ provider: Provider, given conditions: Conditions, uptime: TimeInterval, now: Date) -> Bool {
        self.row(provider, given: conditions, uptime: uptime, now: now).isEnabled
    }

    public func row(_ provider: Provider, given conditions: Conditions, uptime: TimeInterval, now: Date) -> Row {
        let title = conditions.isSignedOut ? "Check sign-in" : "Refresh"
        // An in-flight refresh also holds the cooldown, so it is reported as what it is rather
        // than as a countdown the user cannot act on yet.
        if conditions.isRefreshing {
            return Row(
                title: conditions.isSignedOut ? "Checking…" : "Refreshing…",
                trailingText: nil,
                isEnabled: false,
                isInProgress: true
            )
        }
        let wait = conditions.allowsCredentialRecovery
            ? Self.serverRemaining(conditions, now: now)
            : self.remaining(provider, given: conditions, uptime: uptime, now: now)
        guard wait > 0 else { return Row(title: title, trailingText: nil, isEnabled: true) }
        // Rounded up: the row must never read "0s" while a click is still refused.
        return Row(title: title, trailingText: "\(Int(wait.rounded(.up)))s", isEnabled: false)
    }

    /// Starts `provider`'s minute without asking, for a refresh that ran anyway.
    public mutating func recordRefresh(_ provider: Provider, uptime: TimeInterval) {
        var gate = self.gate(provider)
        gate.recordRefresh(at: uptime)
        self.gates[provider] = gate
    }

    private static func serverRemaining(_ conditions: Conditions, now: Date) -> TimeInterval {
        guard let deadline = conditions.serverRetryAfter else { return 0 }
        return max(0, deadline.timeIntervalSince(now))
    }

    private func gate(_ provider: Provider) -> RefreshCooldownGate {
        self.gates[provider]
            ?? RefreshCooldownGate(minimumInterval: self.minimumInterval, tolerance: self.tolerance)
    }
}
