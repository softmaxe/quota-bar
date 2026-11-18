import Darwin
import Foundation

/// The outcome of scanning one usage source. OpenCode additionally checks that its
/// OpenAI OAuth account matches Codex before including newly observed requests.
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
