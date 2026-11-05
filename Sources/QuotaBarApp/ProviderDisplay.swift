import QuotaBarCore
import Foundation

/// A quota refresh problem, separate from a missing login and from the local usage scan.
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
    /// The server's retry date after it rate-limited a quota request.
    var retryDeadline: Date?
    var signedOutReason: String?
    var localScanStatus: LocalScanStatus = .idle
    /// What past readings say about how fast each window is being spent.
    var pace = QuotaPace()
    /// No credentials on this machine: the enabled status item explains how to sign in.
    var isSignedOut = false
    /// Lets the existing Refresh row bypass the API cooldown for one explicit delegated repair.
    var canAttemptCredentialRecovery = false

    /// Dim the menu bar icon when the newest attempt failed.
    var isStale: Bool { self.error != nil }
}
