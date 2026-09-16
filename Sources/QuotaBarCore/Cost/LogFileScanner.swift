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
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        guard let previous else {
            if size == 0 { return nil }
            let digest = try self.prefixDigest(of: url, byteCount: min(Int64(Self.prefixDigestBytes), size))
            return ScanPlan(
                cursor: FileCursor(inode: inode, size: size, offset: 0, prefixDigest: digest),
                requiresFullReparse: true,
                requiresScan: true
            )
        }

        // For files smaller than 64KB, hash only the bytes that existed during the previous scan.
        // Hashing the newly appended bytes would make every append look like an in-place rewrite.
        let priorPrefixBytes = min(Int64(Self.prefixDigestBytes), previous.size)
        let priorPrefixDigest = try self.prefixDigest(of: url, byteCount: priorPrefixBytes)
        let currentPrefixBytes = min(Int64(Self.prefixDigestBytes), size)
        let currentPrefixDigest = currentPrefixBytes == priorPrefixBytes
            ? priorPrefixDigest
            : try self.prefixDigest(of: url, byteCount: currentPrefixBytes)
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
                            handle(UnsafeRawBufferPointer(start: base.advanced(by: lineStart), count: length))
                        }
                    } else {
                        carry.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: lineStart), count: length))
                        carry.withUnsafeBytes(handle)
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

    private static func prefixDigest(of url: URL, byteCount: Int64) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let head = try file.read(upToCount: max(0, Int(byteCount))) ?? Data()
        return SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
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
