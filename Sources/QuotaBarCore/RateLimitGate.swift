// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageRateLimitGate.swift
//
// The quota endpoints are shared with the CLIs themselves, so a 429 has to stop us from asking
// again until the window passes. Without this, every menu open pushes further into the limit.

import Foundation

public actor UsageRateLimitGate {
    public static let shared = UsageRateLimitGate()

    /// Used when the server declines to say how long to wait.
    private static let defaultBackoff: TimeInterval = 5 * 60
    /// A server-supplied Retry-After far in the future is more likely a bug than a real window.
    private static let maxBackoff: TimeInterval = 60 * 60

    private var blockedUntil: [Provider: Date] = [:]

    public init() {}

    /// When the provider is still inside a rate-limit window, the date it lifts.
    public func blocked(_ provider: Provider, now: Date = Date()) -> Date? {
        guard let until = self.blockedUntil[provider] else { return nil }
        if until <= now {
            self.blockedUntil[provider] = nil
            return nil
        }
        return until
    }

    public func recordRateLimit(_ provider: Provider, retryAfter: Date?, now: Date = Date()) {
        let requested = retryAfter?.timeIntervalSince(now) ?? Self.defaultBackoff
        let clamped = min(Self.maxBackoff, max(Self.defaultBackoff, requested))
        self.blockedUntil[provider] = now.addingTimeInterval(clamped)
    }

    public func recordSuccess(_ provider: Provider) {
        self.blockedUntil[provider] = nil
    }
}
