import QuotaBarCore
import Foundation

/// Pi Agent session lines in, observed requests out, with no recorder.
enum PiAgentAdapterTests {
    static func run() {
        Self.onlyCodexAssistantMessagesBecomeRequests()
        Self.timestampComesFromMillisecondsOrTheEntry()
    }

    /// Only assistant messages answered by the `openai-codex` provider count toward Codex. Each is
    /// keyed by its entry id, which survives forks, and is recorded as Standard because Pi Agent's
    /// logs carry no Fast signal.
    private static func onlyCodexAssistantMessagesBecomeRequests() {
        let root = Self.temporaryRoot("providers")
        defer { try? FileManager.default.removeItem(at: root) }
        PiSessionFile.write(root: root, "project/session.jsonl", lines: [
            PiSessionFile.message("codex", provider: "openai-codex", input: 10, output: 20, cacheWrite: 30, cacheRead: 40),
            PiSessionFile.message("other", provider: "anthropic", input: 10),
            PiSessionFile.message("user", role: "user", input: 10),
            PiSessionFile.message("empty", provider: "openai-codex"),
            #"{"type":"model_change","provider":"openai-codex","model":"gpt-5.6-luna"}"#,
        ])

        let requests = Self.requests(root: root)
        Harness.expectEqual(requests?.map(\.key), ["codex"], "only openai-codex assistant messages with tokens are requests")
        Harness.expectEqual(
            requests?.first,
            ObservedRequest(
                key: "codex",
                timestamp: Date(timeIntervalSince1970: 1_788_264_000),
                model: "gpt-5.6-luna",
                tokens: TokenTotals(input: 10, output: 20, cacheWrite: 30, cacheRead: 40),
                isFast: false
            ),
            "a Codex message maps its tokens, time, and raw model, and is Standard"
        )
    }

    /// Newer sessions stamp the message in epoch milliseconds; older entries carry only an
    /// ISO-8601 timestamp on the entry itself.
    private static func timestampComesFromMillisecondsOrTheEntry() {
        let root = Self.temporaryRoot("timestamps")
        defer { try? FileManager.default.removeItem(at: root) }
        PiSessionFile.write(root: root, "project/session.jsonl", lines: [
            PiSessionFile.message("milliseconds", milliseconds: 1_788_264_000_500, input: 1),
            PiSessionFile.message("iso", milliseconds: nil, entryTimestamp: "2026-09-01T12:00:00Z", input: 1),
            PiSessionFile.message("undated", milliseconds: nil, input: 1),
        ])

        let dates = Dictionary(
            (Self.requests(root: root) ?? []).map { ($0.key ?? "", $0.timestamp) },
            uniquingKeysWith: { first, _ in first }
        )
        Harness.expectEqual(dates["milliseconds"], Date(timeIntervalSince1970: 1_788_264_000.5), "a millisecond message time is used")
        Harness.expectEqual(dates["iso"], Date(timeIntervalSince1970: 1_788_264_000), "an ISO-8601 entry time is the fallback")
        Harness.expect(dates["undated"] == nil, "a message with no time is skipped")
    }

    private static func requests(root: URL) -> [ObservedRequest]? {
        do {
            return try PiAgentAdapter(env: isolatedEnvironment(root: root)).requests()
        } catch {
            Harness.expect(false, "reading the Pi Agent fixture threw: \(error)")
            return nil
        }
    }

    private static func temporaryRoot(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-pi-adapter-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        return root
    }
}

/// Pi Agent session files under `<root>/pi/sessions`, where `isolatedEnvironment(root:)` points
/// Pi Agent, written the way Pi Agent logs messages.
enum PiSessionFile {
    static func write(root: URL, _ relativePath: String, lines: [String]) {
        let file = root.appendingPathComponent("pi/sessions").appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Pi Agent's sign-in to OpenAI, and Codex's, so eligibility can be decided.
    static func signIn(root: URL, piAccount: String, codexAccount: String = "account-a") {
        let codex = root.appendingPathComponent("codex")
        let pi = root.appendingPathComponent("pi")
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
        try? #"{"tokens":{"account_id":"\#(codexAccount)"}}"#.write(
            to: codex.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        try? #"{"openai-codex":{"type":"oauth","accountId":"\#(piAccount)"}}"#.write(
            to: pi.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
    }

    static func message(
        _ id: String,
        role: String = "assistant",
        provider: String = "openai-codex",
        model: String = "gpt-5.6-luna",
        milliseconds: Int64? = 1_788_264_000_000,
        entryTimestamp: String? = nil,
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0
    ) -> String {
        let time = milliseconds.map { #","timestamp":\#($0)"# } ?? ""
        let entryTime = entryTimestamp.map { #","timestamp":"\#($0)""# } ?? ""
        return #"{"type":"message","id":"\#(id)"\#(entryTime),"message":{"role":"\#(role)","provider":"\#(provider)","model":"\#(model)"\#(time),"usage":{"input":\#(input),"output":\#(output),"cacheWrite":\#(cacheWrite),"cacheRead":\#(cacheRead)}}}"#
    }
}
