import Foundation

/// The outcome of scanning one agent that writes into Codex's column. OpenCode and Pi Agent both
/// ride on the user's OpenAI account, so both report the same four outcomes and only the name in
/// the sentence differs.
public enum ExternalAgentScanStatus: Sendable, Equatable {
    case idle
    case accountMismatch
    case nonOAuth
    case error(String)

    public func message(agent: String) -> String? {
        switch self {
        case .idle: nil
        case .accountMismatch: "\(agent) usage is not included because its OpenAI account differs from Codex."
        case .nonOAuth: "\(agent) usage is not included because OpenAI OAuth is not active."
        case .error: "\(agent) usage could not be scanned. Existing totals were kept."
        }
    }
}

public typealias OpenCodeScanStatus = ExternalAgentScanStatus
public typealias PiAgentScanStatus = ExternalAgentScanStatus

/// Whether one agent's usage counts toward the Codex total.
enum ExternalAgentEligibility {
    case eligible
    case ineligible(ExternalAgentScanStatus)
    case indeterminate

    /// An agent is included only when it is signed in with OAuth to the same OpenAI account Codex
    /// uses. An account either side cannot name is indeterminate rather than a mismatch, so a
    /// half-configured install neither drops usage silently nor accuses the user of a mismatch.
    static func matchingCodexAccount(
        type: String?,
        accountId: String?,
        codexAccountId: String?
    ) -> Self {
        guard type?.lowercased() == "oauth" else { return .ineligible(.nonOAuth) }
        guard let left = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !left.isEmpty,
              let right = codexAccountId, !right.isEmpty else {
            return .indeterminate
        }
        return left == right ? .eligible : .ineligible(.accountMismatch)
    }

    /// Whether this agent's rows count, and what the settings pane should say about it. An
    /// indeterminate account answers neither question, so it returns nil and the caller reports
    /// the scan as failed rather than silently dropping or silently counting the usage.
    var resolved: (included: Bool, status: ExternalAgentScanStatus)? {
        switch self {
        case .eligible: (included: true, status: .idle)
        case let .ineligible(reason): (included: false, status: reason)
        case .indeterminate: nil
        }
    }
}
