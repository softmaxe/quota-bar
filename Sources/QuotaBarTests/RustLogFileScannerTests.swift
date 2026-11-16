import Foundation
import QuotaBarCore

/// Differential checks include callback order, full borrowed bytes and consumed offsets.
enum RustLogFileScannerTests {
    private struct Result: Equatable {
        var inspected: [Data] = []
        var handled: [Data] = []
        var consumed: Int64?
        var error: Int?
    }

    static func run() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-rust-lines-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("synthetic 空格.jsonl")
            let chunk = 1 << 20
            let fixtures: [Data] = [
                Data(), Data("\n\nshort\r\npartial".utf8),
                Data(repeating: 97, count: chunk - 1) + Data("\nnext\n".utf8),
                Data(repeating: 97, count: chunk) + Data("\nnext\n".utf8),
                Data(repeating: 97, count: chunk * 2 + 31) + Data("\n\nlast\npartial".utf8),
                Data(repeating: 33, count: chunk * 3 + 71) + Data("\naccepted\npartial".utf8),
                Data([0, 255, 128, 10, 97, 0, 10]),
            ]
            for (index, bytes) in fixtures.enumerated() {
                try bytes.write(to: path)
                let bounds: [(Int64, Int64?)] = [
                    (0, nil), (0, 0), (-1, 7), (0, -1), (0, 65_536),
                    (0, Int64(chunk)), (0, Int64(chunk + 1)),
                    (0, Int64(bytes.count)), (1, nil),
                    (Int64(chunk - 1), nil), (Int64(bytes.count + 10), nil),
                ]
                for (offset, limit) in bounds {
                    let swift = self.scan(path, offset: offset, limit: limit, rust: false)
                    let rust = self.scan(path, offset: offset, limit: limit, rust: true)
                    Harness.expectEqual(rust, swift, "Rust line scan matches Swift fixture \(index), offset \(offset), limit \(String(describing: limit))")
                }
            }
            for url in [root, root.appendingPathComponent("missing.jsonl")] {
                Harness.expectEqual(
                    self.scan(url, offset: 0, limit: nil, rust: true),
                    self.scan(url, offset: 0, limit: nil, rust: false),
                    "Rust line scan preserves open/read errors without callbacks"
                )
            }
            try Data("outer\ninner\n".utf8).write(to: path)
            var outerCount = 0
            var nestedCount = 0
            let offset = try LogFileScanner.readLines(of: path, from: 0) { _ in
                outerCount += 1
                _ = try? LogFileScanner.readLines(of: path, from: 0) { _ in nestedCount += 1 }
            }
            Harness.expectEqual(offset, 12, "Rust callback reentry preserves outer cursor")
            Harness.expectEqual(outerCount, 2, "Rust callback reentry keeps outer records")
            Harness.expectEqual(nestedCount, 4, "Rust callback contexts remain independent")
        } catch {
            Harness.expect(false, "Rust scanner fixture setup failed: \(error)")
        }
    }

    private static func scan(_ path: URL, offset: Int64, limit: Int64?, rust: Bool) -> Result {
        var result = Result()
        let wanted: (UnsafeRawBufferPointer) -> Bool = { bytes in
            result.inspected.append(Data(bytes))
            return bytes.first != 33
        }
        let handle: (UnsafeRawBufferPointer) -> Void = { bytes in result.handled.append(Data(bytes)) }
        do {
            if rust {
                result.consumed = try LogFileScanner.readLines(of: path, from: offset, upTo: limit,
                                                              where: wanted, handle: handle)
            } else {
                result.consumed = try SwiftLogLineScanner.readLines(of: path, from: offset, upTo: limit,
                                                                   where: wanted, handle: handle)
            }
        } catch { result.error = (error as NSError).code }
        return result
    }
}
