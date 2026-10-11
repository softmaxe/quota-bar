import Darwin
import Foundation

/// The outcome of scanning one Usage source. Any source can fail; OpenCode and Pi Agent also ride
/// on the user's OpenAI account, so they can be left out for an account that is not Codex's. Only
/// the name in the sentence differs between sources.
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

    /// Reads the sign-in stored under `entry` in an agent's `auth.json` (an object with `type`
    /// and `accountId`) and checks it against the Codex account. A file either side cannot read
    /// or decode is indeterminate.
    static func signIn(authFile: URL, entry: String, env: [String: String]) -> Self {
        do {
            let data = try Data(contentsOf: authFile)
            let codexAccountId = try CodexCredentialsStore.accountId(env: env)
            let decoder = JSONDecoder()
            decoder.userInfo[AgentAuthFile.entryKey] = entry
            guard let signIn = try decoder.decode(AgentAuthFile.self, from: data).signIn else { return .indeterminate }
            return .matchingCodexAccount(
                type: signIn.type,
                accountId: signIn.accountId,
                codexAccountId: codexAccountId
            )
        } catch {
            return .indeterminate
        }
    }

    /// How an agent riding on the Codex account is surveyed: absent until `marker` exists, failed
    /// while its sign-in cannot be checked, otherwise present with the batch's `included` flag and
    /// status. The sign-in is checked before `stamp` examines the agent's files, and a
    /// `SnapshotReadError` thrown there fails the survey for its reason.
    static func survey<Stamp: Hashable>(
        installedAt marker: URL,
        authFile: URL,
        entry: String,
        env: [String: String],
        stamp: () throws -> Stamp?
    ) -> SnapshotSurvey<Stamp> {
        guard FileManager.default.fileExists(atPath: marker.path) else { return .absent }
        guard let (included, status) = Self.signIn(authFile: authFile, entry: entry, env: env).resolved else {
            return .failed(.auth)
        }
        do {
            return .present(stamp: try stamp(), included: included, status: status)
        } catch {
            return .failed((error as? SnapshotReadError)?.failure ?? .sessions)
        }
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

/// An agent's `auth.json`, of which only the one entry naming its OpenAI sign-in is decoded, so
/// other providers' entries in any shape cannot fail the check.
private struct AgentAuthFile: Decodable {
    static let entryKey = CodingUserInfoKey(rawValue: "entry")!

    struct SignIn: Decodable {
        let type: String?
        let accountId: String?
    }

    let signIn: SignIn?

    init(from decoder: Decoder) throws {
        guard let entry = decoder.userInfo[Self.entryKey] as? String,
              let key = EntryKey(stringValue: entry) else {
            self.signIn = nil
            return
        }
        self.signIn = try decoder.container(keyedBy: EntryKey.self).decodeIfPresent(SignIn.self, forKey: key)
    }

    private struct EntryKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Identity of one file at the moment it was examined: which file it is and when it last
/// changed. A snapshot source whose files keep their stamps is not read again.
struct FileStamp: Hashable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Double
    let changed: Double

    /// nil when no file exists at `path`. Throws when it exists but cannot be examined.
    static func examine(_ path: String) throws -> FileStamp? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStamp(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
            changed: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
        )
    }
}
