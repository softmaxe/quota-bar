import QuotaBarCore
import Foundation

/// The Usage recorder's interface: logs in temporary directories are recorded into a temporary
/// database, and the checks read back the Recorded usage the menu and the report would see.
enum UsageRecorderTests {
    static func run() async {
        Self.claudeRequestsSettleLongContextAndFast()
        Self.claudeReplaysCountOnceAtTheFinalOutput()
        Self.appendedTranscriptResumesWhereItStopped()
        Self.rewrittenTranscriptKeepsMessagesRewrittenAway()
        Self.rewrittenTranscriptKeepsRecordedMessages()
        Self.midFileFailureLeavesNoRows()
    }

    /// A Claude Code request is recorded under its model ID, with its Long-context tier settled
    /// against the rate card per request and Fast taken from the line's `speed`.
    private static func claudeRequestsSettleLongContextAndFast() {
        let fixture = RecorderFixture(name: "tiers")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "small", model: "claude-tier-20260101", input: 1_000, output: 10),
            ClaudeLine.assistant(id: "large", model: "claude-tier", input: 300_000, output: 10),
            ClaudeLine.assistant(id: "fast", model: "claude-tier", input: 2_000, output: 10, speed: "fast"),
        ])
        let rateCard = RateCard(overrides: [
            "claude-tier": ModelPricing(input: 1, output: 1, thresholdTokens: 200_000, inputAbove: 2, outputAbove: 2),
        ])

        fixture.record(.claude, rateCard: rateCard)
        let usage = fixture.recorded(.claude)

        Harness.expectEqual(
            usage[RecordedTier(model: "claude-tier", longContext: false, isFast: false)]?.input,
            1_000,
            "a dated model name is recorded under its model ID, below the threshold"
        )
        Harness.expectEqual(
            usage[RecordedTier(model: "claude-tier", longContext: true, isFast: false)]?.input,
            300_000,
            "a request above the threshold is recorded in the Long-context tier"
        )
        Harness.expectEqual(
            usage[RecordedTier(model: "claude-tier", longContext: false, isFast: true)]?.input,
            2_000,
            "a fast-speed request is recorded as Fast"
        )
        Harness.expectEqual(usage.count, 3, "each tier is recorded separately")
    }
}

extension UsageRecorderTests {
    /// Claude Code streams a message as several lines whose output grows, and replays finished
    /// messages into resumed and forked transcripts. Each message counts once, at its final size.
    fileprivate static func claudeReplaysCountOnceAtTheFinalOutput() {
        let fixture = RecorderFixture(name: "replay")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/first.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 100, output: 5),
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 100, output: 50),
        ])
        fixture.writeClaudeTranscript("app/fork.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 100, output: 50),
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 100, output: 20),
        ])

        fixture.record(.claude)

        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)],
            TokenTotals(input: 100, output: 50),
            "a streamed and replayed message is recorded once, at its largest output"
        )
    }

    /// Only the bytes appended since the last recording are read, so earlier requests are not
    /// counted again.
    fileprivate static func appendedTranscriptResumesWhereItStopped() {
        let fixture = RecorderFixture(name: "append")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "a", model: "claude-opus-5", input: 10, output: 1),
        ])
        fixture.record(.claude)
        fixture.appendClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "b", model: "claude-opus-5", input: 20, output: 2),
        ])
        fixture.record(.claude)
        fixture.record(.claude)

        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)],
            TokenTotals(input: 30, output: 3),
            "an appended transcript adds only its new requests"
        )
    }

    /// A transcript rewritten in place is read again from the start. Its new messages are added,
    /// and a message the rewrite removed stays recorded, since it was billed.
    fileprivate static func rewrittenTranscriptKeepsMessagesRewrittenAway() {
        let fixture = RecorderFixture(name: "rewrite")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "old", model: "claude-opus-5", input: 10, output: 1),
        ])
        fixture.record(.claude)
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "new", model: "claude-opus-5", input: 70, output: 7),
            ClaudeLine.assistant(id: "next", model: "claude-opus-5", input: 200, output: 20),
        ])
        fixture.record(.claude)

        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)],
            TokenTotals(input: 280, output: 28),
            "the removed message still counts beside the rewritten transcript's new messages"
        )
    }

    /// A message that appeared in a transcript was billed. Rewriting the transcript it was first
    /// recorded from must not lose it, even when a second transcript replayed it and its cursor
    /// has already moved past it.
    fileprivate static func rewrittenTranscriptKeepsRecordedMessages() {
        let fixture = RecorderFixture(name: "rewrite-keep")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/first.jsonl", lines: [
            ClaudeLine.assistant(id: "shared", model: "claude-opus-5", input: 100, output: 10),
        ])
        fixture.record(.claude)
        fixture.writeClaudeTranscript("app/resumed.jsonl", lines: [
            ClaudeLine.assistant(id: "shared", model: "claude-opus-5", input: 100, output: 10),
        ])
        fixture.record(.claude)
        fixture.writeClaudeTranscript("app/first.jsonl", lines: [
            ClaudeLine.assistant(id: "other", model: "claude-opus-5", input: 7, output: 1),
            ClaudeLine.assistant(id: "later", model: "claude-opus-5", input: 20, output: 2),
        ])
        fixture.record(.claude)

        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)],
            TokenTotals(input: 127, output: 13),
            "a replayed message stays recorded, once, after its first transcript is rewritten"
        )
    }

    /// A file that fails partway through records none of it and keeps its cursor, so the next
    /// successful pass counts every request exactly once.
    fileprivate static func midFileFailureLeavesNoRows() {
        let fixture = RecorderFixture(name: "rollback")
        defer { fixture.remove() }
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "a", model: "claude-opus-5", input: 10, output: 1),
            ClaudeLine.assistant(id: "poison", model: "claude-opus-5", input: 20, output: 2),
            ClaudeLine.assistant(id: "c", model: "claude-opus-5", input: 40, output: 4),
        ])
        let failing = FailingAdapter(
            wrapped: ClaudeCodeAdapter(env: fixture.env),
            failingOn: Data(#""id":"poison""#.utf8)
        )

        fixture.recorder?.record(failing, rateCard: RateCard())
        Harness.expectEqual(fixture.recorder?.scanStatus(of: .claude), .idle, "a failing file is skipped, not a failed source")
        Harness.expect(fixture.recorded(.claude).isEmpty, "a file that fails partway leaves no rows")

        fixture.record(.claude)
        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)],
            TokenTotals(input: 70, output: 7),
            "the retry after a failure counts each request once"
        )
    }
}

/// Wraps an adapter so parsing throws on a line containing `marker`, standing in for a failure
/// partway through a file.
private struct FailingAdapter<Wrapped: AppendedLogAdapter>: AppendedLogAdapter {
    let wrapped: Wrapped
    let failingOn: Data

    var source: AppendedLogSource { self.wrapped.source }
    func logFiles() -> [URL] { self.wrapped.logFiles() }
    func isWanted(_ line: UnsafeRawBufferPointer) -> Bool { self.wrapped.isWanted(line) }

    func parser(for file: URL, resumingAt offset: Int64, savedState: String?) -> Parser {
        Parser(
            wrapped: self.wrapped.parser(for: file, resumingAt: offset, savedState: savedState),
            marker: self.failingOn
        )
    }

    struct Parser: AppendedLogParser {
        var wrapped: Wrapped.Parser
        let marker: Data

        var savedState: String? { self.wrapped.savedState }

        mutating func request(in line: UnsafeRawBufferPointer) throws -> ObservedRequest? {
            if Data(line).range(of: self.marker) != nil { throw CocoaError(.fileReadCorruptFile) }
            return try self.wrapped.request(in: line)
        }
    }
}

/// The attributes Recorded usage keeps per row, across every day.
struct RecordedTier: Hashable {
    let model: String
    let longContext: Bool
    let isFast: Bool
}

/// Assistant lines in the shape Claude Code writes them.
enum ClaudeLine {
    static func assistant(
        id: String,
        requestId: String? = nil,
        model: String,
        input: Int,
        output: Int,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        speed: String? = nil,
        timestamp: String = "2026-09-01T12:00:00Z"
    ) -> String {
        let speedField = speed.map { #","speed":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(requestId ?? "req-\(id)")","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead)\#(speedField)}}}"#
    }
}

/// A temporary log root and database for one recorder check.
struct RecorderFixture {
    let root: URL
    let recorder: UsageRecorder?

    init(name: String) {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-recorder-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: self.root)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        do {
            self.recorder = try UsageRecorder(databaseURL: self.root.appendingPathComponent("usage.sqlite"))
        } catch {
            Harness.expect(false, "recorder \(name) failed to open: \(error)")
            self.recorder = nil
        }
    }

    var databaseURL: URL { self.root.appendingPathComponent("usage.sqlite") }
    var env: [String: String] { isolatedEnvironment(root: self.root) }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func claudeTranscript(_ relativePath: String) -> URL {
        self.root.appendingPathComponent("claude/projects").appendingPathComponent(relativePath)
    }

    func writeClaudeTranscript(_ relativePath: String, lines: [String]) {
        let file = self.claudeTranscript(relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func appendClaudeTranscript(_ relativePath: String, lines: [String]) {
        guard let handle = try? FileHandle(forWritingTo: self.claudeTranscript(relativePath)) else {
            Harness.expect(false, "could not append to \(relativePath)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func record(_ provider: Provider, rateCard: RateCard = RateCard()) {
        self.recorder?.record(provider, rateCard: rateCard, env: self.env)
    }

    /// Recorded usage of a provider summed across days, keyed by model and tier.
    func recorded(_ provider: Provider) -> [RecordedTier: TokenTotals] {
        do {
            let reader = try RecordedUsageReader(databaseURL: self.databaseURL)
            var totals: [RecordedTier: TokenTotals] = [:]
            for (_, tiers) in try reader.dailyUsage(provider: provider, fromDay: "0000-00-00", rateCard: RateCard()) {
                for (tier, tokens) in tiers {
                    let key = RecordedTier(model: tier.model, longContext: tier.longContext, isFast: tier.isFast)
                    totals[key, default: TokenTotals()] += tokens
                }
            }
            return totals
        } catch {
            Harness.expect(false, "reading recorded usage threw: \(error)")
            return [:]
        }
    }
}
