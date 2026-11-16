import Darwin
import Foundation

/// Frozen f8df98b streaming implementation used only to check the Rust boundary.
enum SwiftLogLineScanner {
    private static let chunkSize = 1 << 20
    private static let longLinePrefixBytes = 64 * 1024
    static func readLines(
        of url: URL,
        from offset: Int64,
        upTo limit: Int64? = nil,
        where isWanted: (UnsafeRawBufferPointer) -> Bool = { _ in true },
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
        var skippingLine = false
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
                    if skippingLine {
                        skippingLine = false
                    } else if carry.isEmpty {
                        let line = UnsafeRawBufferPointer(start: base.advanced(by: lineStart), count: length)
                        if length > 0, isWanted(line) {
                            // Handlers parse with Foundation, whose autoreleased objects would
                            // otherwise pile up until the scan's task finishes.
                            autoreleasepool { handle(line) }
                        }
                    } else {
                        carry.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: lineStart), count: length))
                        if carry.withUnsafeBytes(isWanted) {
                            autoreleasepool { carry.withUnsafeBytes(handle) }
                        }
                        carry.removeAll(keepingCapacity: true)
                    }
                    consumed = chunkStart + Int64(newline) + 1
                    lineStart = newline + 1
                }
                if lineStart < count, !skippingLine {
                    let wasShort = carry.count < Self.longLinePrefixBytes
                    carry.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: lineStart), count: count - lineStart))
                    if wasShort, carry.count >= Self.longLinePrefixBytes, !carry.withUnsafeBytes(isWanted) {
                        skippingLine = true
                        carry.removeAll(keepingCapacity: true)
                    }
                }
            }
            readPosition += Int64(count)
        }

        return consumed
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

}
