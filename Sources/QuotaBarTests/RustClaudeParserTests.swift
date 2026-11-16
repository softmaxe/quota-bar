import Foundation
import QuotaBarCore
import CQuotaBarRust

/// The original decoder defines compatibility; adversarial input must not change recorded usage.
enum RustClaudeParserTests {
    static func run() {
        Harness.expect(MemoryLayout<QBClaudeResult>.size == 152 && MemoryLayout<QBClaudeResult>.alignment == 8
                       && MemoryLayout<QBClaudeResult>.offset(of: \.counts) == 8
                       && MemoryLayout<QBClaudeResult>.offset(of: \.timestamp) == 48
                       && MemoryLayout<QBClaudeResult>.offset(of: \.owner) == 144,
                       "C-imported Claude result matches the Rust ABI layout")
        let reference = ClaudeCodeAdapter.FoundationParser()
        let candidate = ClaudeCodeAdapter.Parser()
        var samples: [Data] = []
        func append(_ text: String) { samples.append(Data(text.utf8)) }
        let prefix = #"{"type":"assistant","timestamp":"2026-11-16T12:34:56.123Z","requestId":"r","message":{"id":"m","model":"claude-test","usage":UREPLACE}}"#
        let scalars = ["null", "true", "false", "0", "1", "-1", "1.9", "-0.9", "1e20", "1e308", "1e999",
                       "9007199254740993.0", "9007199254740993e0", "9.21e18", "-9.21e18",
                       "9223372036854775807", "9223372036854775808", #""+123""#, #"" 123""#,
                       #""123 ""#, #""00012""#, #""-1""#, #""1.5""#, #""9223372036854775808""#,
                       "{}", "[]", "[1]", #"{"unexpected":1}"#]
        for field in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
            for scalar in scalars {
                let defaults = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .filter { $0 != field }.map { "\"\($0)\":10" }.joined(separator: ",")
                append(prefix.replacingOccurrences(of: "UREPLACE", with: "{\(defaults),\"\(field)\":\(scalar)}"))
            }
        }
        for usage in ["null", "[]", "[1]", "false", "1", "{}",
                      #"{"input_tokens":1,"input_tokens":2}"#,
                      #"{"input_tokens":1,"input_\u0074okens":2}"#,
                      #"{"input_tokens":9223372036854775807,"output_tokens":1}"#,
                      #"{"input_tokens":1,"cache_creation_input_tokens":3,"cache_creation":[2]}"#,
                      #"{"input_tokens":1,"cache_creation_input_tokens":3,"cache_creation":{"ephemeral_1h_input_tokens":-1}}"#] {
            append(prefix.replacingOccurrences(of: "UREPLACE", with: usage))
        }
        let valid = prefix.replacingOccurrences(of: "UREPLACE", with: #"{"input_tokens":10,"output_tokens":2,"speed":"FAST"}"#)
        append(valid)
        append(valid.replacingOccurrences(of: #""type":"assistant""#, with: #""type":"user","type":"assistant""#))
        append(valid.replacingOccurrences(of: "claude-test", with: #"\u0000model"#))
        append(valid.replacingOccurrences(of: "claude-test", with: #" \n\u00a0claude-test\t"#))
        append(valid.replacingOccurrences(of: "claude-test", with: "<synthetic>"))
        append(valid.replacingOccurrences(of: #""requestId":"r","message":{"id":"m","model""#,
                                         with: #""message":{"model""#))
        append(valid.replacingOccurrences(of: #""requestId":"r","message":{"id":"m","model""#,
                                         with: #""uuid":"u\u0000id","message":{"model""#))
        append(valid.replacingOccurrences(of: "2026-11-16T12:34:56.123Z", with: "2026-11-16T20:34:56.123456789+08:00"))
        if let object = try? JSONSerialization.jsonObject(with: Data(valid.utf8)),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            samples.append(pretty)
        }
        samples.append(Data([0xff, 0xfe, 0x7b, 0x7d]))
        for end in valid.utf8.indices {
            samples.append(Data(valid.utf8[..<end]))
        }

        // Include malformed byte-level mutations rather than only valid encoder-generated JSON.
        var state: UInt64 = 0x434c41554445
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            var bytes = Array(valid.utf8)
            let position = Int(state % UInt64(bytes.count))
            bytes[position] = UInt8(truncatingIfNeeded: state >> 32)
            samples.append(Data(bytes))
        }
        var failures = 0
        for (index, sample) in samples.enumerated() {
            let equal = sample.withUnsafeBytes { reference.request(in: $0) == candidate.request(in: $0) }
            if !equal {
                failures += 1
                Harness.expect(false, "Rust Claude parser differs from Foundation at fixture \(index)")
            }
        }
        Harness.expect(failures == 0, "Rust Claude parser matches Foundation for \(samples.count) adversarial buffers")

        var output = QBClaudeResult()
        qb_claude_decode(nil, 1, &output)
        Harness.expect(output.status == QB_CLAUDE_INVALID_ARGUMENT && output.owner == nil,
                       "invalid FFI input reports failure without an owned allocation")
        qb_claude_free(output.owner)
    }
}
