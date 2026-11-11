import QuotaBarCore
import Foundation

/// Transcript lines in, observed requests out, with no database.
enum ClaudeCodeAdapterTests {
    static func run() {
        Self.dedupeKeyPairsMessageAndRequest()
        Self.dedupeKeyFallsBackToTheLineUUID()
        Self.idlessRecordsUseTheirContent()
        Self.syntheticMessagesAreNotRequests()
        Self.cacheBucketsMapToTokenTotals()
        Self.onlyFastSpeedIsFast()
    }

    private static func request(_ line: String) -> ObservedRequest? {
        let parser = ClaudeCodeAdapter(env: [:]).parser(for: URL(fileURLWithPath: "/dev/null"), resumingAt: 0, savedState: nil)
        return Data(line.utf8).withUnsafeBytes { parser.request(in: $0) }
    }

    /// A replayed message carries the same message id and request id in every transcript.
    private static func dedupeKeyPairsMessageAndRequest() {
        let observed = Self.request(ClaudeLine.assistant(id: "msg_1", requestId: "req_1", model: "claude-opus-5", input: 1, output: 1))
        Harness.expectEqual(observed?.key, "msg_1|req_1", "the key pairs the message id with its request id")
        Harness.expectEqual(observed?.model, "claude-opus-5", "the model is reported as the log spelled it")
    }

    /// A transcript UUID remains the identity when neither API id is present.
    private static func dedupeKeyFallsBackToTheLineUUID() {
        let usage = #""usage":{"input_tokens":5,"output_tokens":1}"#
        let withUUID = #"{"type":"assistant","timestamp":"2026-09-01T12:00:00Z","uuid":"line-1","message":{"model":"claude-opus-5",\#(usage)}}"#
        Harness.expectEqual(Self.request(withUUID)?.key, "uuid:line-1", "a line without ids is keyed by its uuid")
    }

    private static func idlessRecordsUseTheirContent() {
        let bare = ClaudeLine.idlessAssistant(sessionID: "session-a", text: "First reply")
        let key = Self.request(bare)?.key
        Harness.expect(key != nil, "a line without any stable id still has an identity")
        Harness.expectEqual(Self.request(bare)?.key, key, "rereading an id-less record keeps its identity")
        do {
            let object = try JSONSerialization.jsonObject(with: Data(bare.utf8))
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            Harness.expectEqual(Self.request(String(decoding: formatted, as: UTF8.self))?.key, key,
                                "JSON key order and whitespace do not change an id-less record's identity")
        } catch {
            Harness.expect(false, "formatting the id-less fixture failed: \(error)")
        }
        let variants = [
            ClaudeLine.idlessAssistant(sessionID: "session-b", text: "First reply"),
            ClaudeLine.idlessAssistant(sessionID: "session-a", text: "Another reply"),
            bare.replacingOccurrences(of: "12:00:00Z", with: "12:00:01Z"),
            bare.replacingOccurrences(of: "\"output_tokens\":1", with: "\"output_tokens\":2"),
        ]
        let keys = variants.compactMap { Self.request($0)?.key }
        Harness.expectEqual(keys.count, variants.count, "distinct id-less fixtures are valid requests")
        Harness.expectEqual(Set(keys + [key!]).count, variants.count + 1,
                            "session, content, timestamp, and usage distinguish id-less records")

        let emptyUUID = bare.replacingOccurrences(of: "\"type\":", with: "\"uuid\":\"\",\"type\":")
        Harness.expectEqual(Self.request(emptyUUID)?.key, Self.request(emptyUUID)?.key,
                            "an empty UUID still gives repeatable identity")
        Harness.expect(Self.request(emptyUUID)?.key != Self.request(
            emptyUUID.replacingOccurrences(of: "First reply", with: "Another reply"))?.key,
            "an empty UUID does not collapse unrelated records")
    }

    /// Claude Code writes `<synthetic>` for messages it made up locally; nothing was billed.
    private static func syntheticMessagesAreNotRequests() {
        let synthetic = ClaudeLine.assistant(id: "s", model: "<synthetic>", input: 10, output: 10)
        Harness.expect(Self.request(synthetic) == nil, "a synthetic message is not a request")
    }

    /// Anthropic's input is already net of cache, and the one-hour cache write is a subset of
    /// all cache writes.
    private static func cacheBucketsMapToTokenTotals() {
        let line = #"{"type":"assistant","timestamp":"2026-09-01T12:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":500,"cache_read_input_tokens":9000,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":400}}}}"#
        Harness.expectEqual(
            Self.request(line)?.tokens,
            TokenTotals(input: 3, output: 7, cacheWrite: 500, cacheWrite1h: 400, cacheRead: 9000),
            "each usage field lands in its token bucket"
        )
        Harness.expectEqual(Self.request(line)?.isFast, false, "a line without speed is Standard")
    }

    /// `usage.speed` is "fast" for a Fast mode request and "standard" otherwise.
    private static func onlyFastSpeedIsFast() {
        let fast = ClaudeLine.assistant(id: "f", model: "claude-opus-5-5", input: 1, output: 1, speed: "fast")
        let standard = ClaudeLine.assistant(id: "s", model: "claude-opus-5-5", input: 1, output: 1, speed: "standard")
        Harness.expectEqual(Self.request(fast)?.isFast, true, "a fast-speed line is Fast")
        Harness.expectEqual(Self.request(standard)?.isFast, false, "a standard-speed line is Standard")
    }
}
