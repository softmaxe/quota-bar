import CryptoKit
import Darwin
import Foundation

/// Streams the newline-delimited records of a JSONL file, resuming from a byte offset.
package enum LogFileScanner {
    private static let prefixDigestBytes = 64 * 1024
    private static let chunkSize = 1 << 20

    package struct ScanPlan {
        package let cursor: FileCursor
        /// True when the file must be re-read from the start and its cached rows dropped.
        package let requiresFullReparse: Bool
        /// True when the scanner has new bytes to inspect or must rebuild a rewritten file.
        package let requiresScan: Bool
    }

    /// Decides whether a file can be resumed. A changed inode, a shrunken file, or a different
    /// 64KB prefix all mean the file was rewritten rather than appended to.
    /// A known copy of the same session may change inode; its size and prefix must still match.
    package static func plan(
        for url: URL,
        previous: FileCursor?,
        matchingSessionCopy: Bool = false
    ) throws -> ScanPlan? {
        // lstat, like `attributesOfItem`, without its extended-attribute lookups. Every tracked
        // file is planned on every refresh, so this runs thousands of times per pass.
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw Self.posixError() }
        let identity = FileIdentity(info)
        let size = Int64(info.st_size)
        let inode = UInt64(info.st_ino)
        let prefixDigest = { (byteCount: Int64) in
            try self.prefixDigest(of: url, byteCount: byteCount, identity: identity)
        }
        guard let previous else {
            if size == 0 { return nil }
            let digest = try prefixDigest(min(Int64(Self.prefixDigestBytes), size))
            return ScanPlan(
                cursor: FileCursor(inode: inode, size: size, offset: 0, prefixDigest: digest),
                requiresFullReparse: true,
                requiresScan: true
            )
        }

        // For files smaller than 64KB, hash only the bytes that existed during the previous scan.
        // Hashing the newly appended bytes would make every append look like an in-place rewrite.
        let priorPrefixBytes = min(Int64(Self.prefixDigestBytes), previous.size)
        let priorPrefixDigest = try prefixDigest(priorPrefixBytes)
        let currentPrefixBytes = min(Int64(Self.prefixDigestBytes), size)
        let currentPrefixDigest = currentPrefixBytes == priorPrefixBytes
            ? priorPrefixDigest
            : try prefixDigest(currentPrefixBytes)
        guard (previous.inode == inode || matchingSessionCopy),
              previous.prefixDigest == priorPrefixDigest,
              size >= previous.size else {
            return ScanPlan(
                cursor: FileCursor(inode: inode, size: size, offset: 0, prefixDigest: currentPrefixDigest),
                requiresFullReparse: true,
                requiresScan: true
            )
        }

        // Refresh the stored digest when a small file grows, especially when it crosses 64KB.
        return ScanPlan(
            cursor: FileCursor(
                inode: inode,
                size: size,
                offset: previous.offset,
                prefixDigest: currentPrefixDigest,
                resumeStateJSON: previous.resumeStateJSON
            ),
            requiresFullReparse: false,
            // An incomplete trailing line leaves offset below size. If the size is unchanged,
            // reading that same partial line again cannot produce a record.
            requiresScan: size > previous.size
        )
    }

    /// Reads complete lines starting at `offset` and returns the offset just past the last
    /// complete line, so a partially written trailing line is re-read next time. `limit` is an
    /// absolute byte offset and is never read past, even when it lands inside a line. The buffer
    /// passed to `handle` is valid only for that call and must not escape it.
    package static func readLines(
        of url: URL,
        from offset: Int64,
        upTo limit: Int64? = nil,
        handle: (UnsafeRawBufferPointer) -> Void
    ) throws -> Int64 {
        let start = max(0, offset)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.lseek(descriptor, off_t(start), SEEK_SET) >= 0 else {
            throw Self.posixError()
        }

        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var carry: [UInt8] = []
        var readPosition = start
        var consumed = start

        while limit.map({ readPosition < $0 }) ?? true {
            let requested = limit.map { min(Int64(Self.chunkSize), max(0, $0 - readPosition)) }
                ?? Int64(Self.chunkSize)
            guard requested > 0 else { break }

            let count: Int = try buffer.withUnsafeMutableBytes { storage in
                var result: Int
                repeat {
                    result = Darwin.read(descriptor, storage.baseAddress, Int(requested))
                } while result < 0 && errno == EINTR
                guard result >= 0 else { throw Self.posixError() }
                return result
            }
            guard count > 0 else { break }

            let chunkStart = readPosition
            buffer.withUnsafeBytes { storage in
                guard let base = storage.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var lineStart = 0
                while lineStart < count,
                      let found = memchr(base.advanced(by: lineStart), Int32(UInt8(ascii: "\n")), count - lineStart) {
                    let newline = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    let length = newline - lineStart
                    if carry.isEmpty {
                        if length > 0 {
                            // Handlers parse with Foundation, whose autoreleased objects would
                            // otherwise pile up until the scan's task finishes.
                            autoreleasepool {
                                handle(UnsafeRawBufferPointer(start: base.advanced(by: lineStart), count: length))
                            }
                        }
                    } else {
                        carry.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: lineStart), count: length))
                        autoreleasepool { carry.withUnsafeBytes(handle) }
                        carry.removeAll(keepingCapacity: true)
                    }
                    consumed = chunkStart + Int64(newline) + 1
                    lineStart = newline + 1
                }
                if lineStart < count {
                    carry.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: lineStart), count: count - lineStart))
                }
            }
            readPosition += Int64(count)
        }

        return consumed
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// What `lstat` reports about a file's contents. The kernel moves the change time on every
    /// write, so an equal identity means the bytes a digest covered cannot have changed.
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec
        let changed: timespec

        init(_ info: Darwin.stat) {
            self.device = info.st_dev
            self.inode = info.st_ino
            self.size = info.st_size
            self.modified = info.st_mtimespec
            self.changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private struct DigestMemo {
        var identity: FileIdentity
        var digests: [Int64: String]
    }

    /// Prefix digests of files that have not changed since they were last hashed. Without it every
    /// refresh re-reads and hashes up to 64KB of every log, even when nothing was appended.
    private static let digestLock = NSLock()
    nonisolated(unsafe) private static var digestMemo: [String: DigestMemo] = [:]

    private static func prefixDigest(of url: URL, byteCount: Int64, identity: FileIdentity) throws -> String {
        let path = url.path
        self.digestLock.lock()
        let memo = self.digestMemo[path]
        self.digestLock.unlock()
        if let memo, memo.identity == identity, let digest = memo.digests[byteCount] { return digest }

        let digest = try self.prefixDigest(of: url, byteCount: byteCount)
        self.digestLock.lock()
        if var entry = self.digestMemo[path], entry.identity == identity {
            entry.digests[byteCount] = digest
            self.digestMemo[path] = entry
        } else {
            self.digestMemo[path] = DigestMemo(identity: identity, digests: [byteCount: digest])
        }
        self.digestLock.unlock()
        return digest
    }

    /// SHA-256 of the first `byteCount` bytes, or of the whole file when it is shorter, as
    /// lowercase hex. Reads with plain syscalls: Foundation's file handles return autoreleased
    /// buffers, and a refresh hashes thousands of files before its task drains them.
    private static func prefixDigest(of url: URL, byteCount: Int64) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { _ = Darwin.close(descriptor) }

        let wanted = max(0, Int(min(byteCount, Int64(Int.max))))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: min(wanted, Self.prefixDigestBytes))
        var remaining = wanted
        while remaining > 0 {
            let count: Int = try buffer.withUnsafeMutableBytes { storage in
                var result: Int
                repeat {
                    result = Darwin.read(descriptor, storage.baseAddress, min(remaining, storage.count))
                } while result < 0 && errno == EINTR
                guard result >= 0 else { throw Self.posixError() }
                return result
            }
            guard count > 0 else { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            remaining -= count
        }
        return Self.hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// All `.jsonl` files under the given roots, skipping unreadable directories.
    static func jsonlFiles(under roots: [URL]) -> [URL] {
        var found: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                guard item.pathExtension == "jsonl" else { continue }
                found.append(item)
            }
        }
        return found
    }
}
