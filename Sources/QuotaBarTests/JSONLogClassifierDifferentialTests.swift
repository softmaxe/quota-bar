import Foundation
import QuotaBarCore

/// The pre-migration Swift classifier is the oracle, including permissive prefix semantics.
enum JSONLogClassifierDifferentialTests {
    static func run() {
        let fixtures = [
            "", "{}", "[]", "null", "{", "{\"type\":", "{\"type\":false}",
            #"{"type":"assistant"}"#, #"{"type":"event_msg"}"#, #"{"type":"turn_context"}"#,
            #"{"type":"assistant"trailing garbage"#, #"{"type":"assistant","type":"user"}"#,
            #"{"type":"user","type":"assistant"}"#, #"{"ty\u0070e":"assistant"}"#,
            #"{"type":"assi\u0073tant"}"#, #"{"x\u0079":0,"type":"assistant"}"#,
            #"{"payload":{"type":"token_count"}}"#, #"{"payload":{"type":"thread_settings_applied"}}"#,
            #"{"payload":{"type":"other"}}"#, #"{"payload":{}}"#, #"{"payload":null}"#,
            #"{"payload":{"type":"token\u005fcount"}}"#, #"{"pay\u006coad":{"type":"token_count"}}"#,
            #"{"skip":[{"type":"assistant"}],"type":"user"}"#,
            #"{"skip":"\"type\":\"assistant\"","type":"user"}"#,
            #"{"skip":[},"type":"assistant"}"#, #"{"skip":],"type":"assistant"}"#,
            #"{"skip":,"type":"assistant"}"#, #"{"skip":1,}"#,
            " \r\n\t{\"skip\":[1,{\"nested\":[true,null]}],\"payload\":{\"type\":\"token_count\"}}",
        ].map { Array($0.utf8) }

        var prefixCount = 0
        for (fixtureIndex, fixture) in fixtures.enumerated() {
            for count in 0...fixture.count {
                guard Self.compare(Array(fixture.prefix(count)), label: "fixture \(fixtureIndex), prefix \(count)") else {
                    return
                }
                prefixCount += 1
            }
        }
        Harness.expect(prefixCount > 500, "Rust classifier matches Swift on every adversarial fixture prefix")

        var generator = Generator()
        for iteration in 0..<10_000 {
            let count = Int(generator.next() % 257)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next() >> 24) }
            guard Self.compare(bytes, label: "arbitrary bytes, seed 0x71626a736f6e, iteration \(iteration)") else {
                return
            }
        }
        Harness.expect(true, "Rust classifier matches Swift on 10,000 seeded arbitrary byte buffers")

        for iteration in 0..<10_000 {
            var bytes = fixtures[Int(generator.next() % UInt64(fixtures.count))]
            for _ in 0..<(1 + Int(generator.next() % 8)) {
                let index = Int(generator.next() % UInt64(bytes.count + 1))
                let byte = UInt8(truncatingIfNeeded: generator.next() >> 24)
                if index < bytes.count && generator.next() & 1 == 0 {
                    bytes[index] = byte
                } else {
                    bytes.insert(byte, at: index)
                }
            }
            guard Self.compare(bytes, label: "mutated fixture, iteration \(iteration)") else { return }
        }
        Harness.expect(true, "Rust classifier matches Swift on 10,000 seeded malformed structural fixtures")

        for plainCount in [0, 1, 15, 16, 17, 31, 32, 33] {
            for suffix in ["", #"\""#, #"\\"#, #"\\\""#] {
                let bytes = Array((#"{"padding":""# + String(repeating: "x", count: plainCount)
                    + suffix + #"","type":"assistant","payload":{"type":"token_count"}}"#).utf8)
                for cut in 0...bytes.count {
                    guard Self.compare(Array(bytes.prefix(cut)), label: "scalar/libc boundary \(plainCount), prefix \(cut)") else {
                        return
                    }
                }
            }
        }
        for slashCount in 0..<128 {
            let bytes = Array((#"{"padding":""# + String(repeating: "\\", count: slashCount)
                + #"","type":"assistant","payload":{"type":"token_count"}}"#).utf8)
            guard Self.compare(bytes, label: "escape parity \(slashCount)") else { return }
        }
        let nested = Array((#"{"padding":"# + String(repeating: "[", count: 16_384)
            + #"{"type":"user"}"# + String(repeating: "]", count: 16_384)
            + #", "type":"assistant","payload":{"type":"token_count"}}"#).utf8)
        guard Self.compare(nested, label: "deep nested decoy uses bounded stack space") else { return }
        for padding in [String(repeating: "x", count: 1_048_576),
                        String(repeating: #"a\"b\\c"#, count: 131_072)] {
            let bytes = Array((#"{"padding":""# + padding
                + #"","type":"assistant","payload":{"type":"token_count"}}"#).utf8)
            let cuts = [0, 1, 12, 13, 31, 255, 65_535, 65_536, bytes.count / 2]
                + Array((bytes.count - 64)...bytes.count)
            for cut in cuts {
                guard Self.compare(Array(bytes.prefix(cut)), label: "large string truncation \(cut)") else { return }
            }
            var invalidUTF8 = bytes
            invalidUTF8[20] = 0xff
            invalidUTF8[21] = 0
            guard Self.compare(invalidUTF8, label: "large string with non-UTF8 and NUL") else { return }
        }
        Harness.expect(true, "Rust classifier preserves large plain/escaped strings, truncation, NUL and escape parity")
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        Harness.expectEqual(JSONLogClassifier.topLevelType(in: empty), .indeterminate, "Rust top-level accepts null empty buffer")
        Harness.expectEqual(JSONLogClassifier.payloadType(in: empty), .indeterminate, "Rust payload accepts null empty buffer")
    }

    private static func compare(_ bytes: [UInt8], label: String) -> Bool {
        bytes.withUnsafeBytes { buffer in
            let top = JSONLogClassifier.topLevelType(in: buffer)
            let payload = JSONLogClassifier.payloadType(in: buffer)
            let expectedTop = SwiftJSONLogClassifier.topLevelType(in: buffer)
            let expectedPayload = SwiftJSONLogClassifier.payloadType(in: buffer)
            let topMatches: Bool
            switch (top, expectedTop) {
            case (nil, nil), (.assistant?, .assistant?), (.eventMessage?, .eventMessage?),
                 (.turnContext?, .turnContext?), (.other?, .other?), (.indeterminate?, .indeterminate?):
                topMatches = true
            default: topMatches = false
            }
            let payloadMatches: Bool
            switch (payload, expectedPayload) {
            case (nil, nil), (.threadSettingsApplied?, .threadSettingsApplied?),
                 (.tokenCount?, .tokenCount?), (.other?, .other?), (.indeterminate?, .indeterminate?):
                payloadMatches = true
            default: payloadMatches = false
            }
            let matches = topMatches && payloadMatches
            if !matches {
                Harness.expect(false, "classifier differential mismatch at \(label): \(bytes.prefix(100)); "
                    + "top \(String(describing: top))/\(String(describing: expectedTop)), "
                    + "payload \(String(describing: payload))/\(String(describing: expectedPayload))")
            }
            return matches
        }
    }

    private struct Generator {
        private var state: UInt64 = 0x71626a736f6e

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
}
