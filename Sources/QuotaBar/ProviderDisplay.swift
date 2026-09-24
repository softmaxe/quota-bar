import QuotaBarCore
import Foundation

/// A quota refresh problem, separate from a missing login and from the local usage scan.
struct ProviderFailure: Equatable {
    enum Kind: Equatable {
        case refresh
        case rateLimited
        case credentialRecovery
        /// The credentials could not be read from the keychain; only an explicit refresh asks again.
        case accessDenied
    }

    var kind: Kind
    var reason: String
    var serverRetryAfter: Date? = nil
}

/// Local usage collection runs independently of the provider's quota request.
enum LocalScanStatus: Equatable {
    case idle
    case scanning
    case completed(Date)
    case failed(String)
}

/// What the card shows for one provider. A failed refresh keeps the last good snapshot and adds
/// an error line, rather than replacing real numbers with an error screen.
struct ProviderDisplay: Equatable {
    var snapshot: UsageSnapshot?
    var cost: CostSnapshot?
    var error: String?
    var failure: ProviderFailure?
    var signedOutReason: String?
    var localScanStatus: LocalScanStatus = .idle
    /// Completed past windows, once enough have been recorded to model a pace from them.
    var history: UsageHistoryDataset?
    /// No credentials on this machine: the enabled status item explains how to sign in.
    var isSignedOut = false
    /// Lets the existing Refresh row bypass the API cooldown for one explicit delegated repair.
    var canAttemptCredentialRecovery = false

    /// The server's retry date; use UsageStore.retryEligibleAt for the effective server/local date.
    var retryDeadline: Date? { self.failure?.serverRetryAfter }

    /// Dim the menu bar icon when the newest attempt failed.
    var isStale: Bool { self.error != nil }
}
