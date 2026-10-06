import QuotaBarCore
import Foundation

/// Codex rollouts recorded through the Usage recorder's interface, read back as Recorded usage.
enum CodexRecordingTests {
    static func run() {
        Self.turnsAccumulatePerModelAndTier()
        Self.appendedRolloutResumesWithItsState()
        Self.rewrittenRolloutIsNotDoubled()
        Self.replacedRolloutWithTheSamePrefixIsReparsed()
        Self.emptiedRolloutKeepsNoRows()
        Self.longContextIsSettledPerTurn()
    }

    private static let rollout = "2026/09/01/rollout-2026-09-01T12-00-00-0199a000-0000-7000-8000-000000000001.jsonl"

    /// Codex turns have no identity of their own, so each turn's delta adds to its model and tier.
    private static func turnsAccumulatePerModelAndTier() {
        let fixture = RecorderFixture(name: "codex-accumulate")
        defer { fixture.remove() }
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 200, output: 20, total: 330),
            CodexLine.turnContext(model: "gpt-5.6-sol", serviceTier: "priority"),
            CodexLine.tokenCount(input: 400, output: 40, total: 770),
        ])

        fixture.record(.codex)
        let usage = fixture.recorded(.codex)

        Harness.expectEqual(
            usage[RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)],
            TokenTotals(input: 300, output: 30),
            "standard turns of one model add up"
        )
        Harness.expectEqual(
            usage[RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: true)],
            TokenTotals(input: 400, output: 40),
            "turns after a priority turn context are recorded as Fast"
        )
        Harness.expectEqual(usage.count, 2, "each tier is recorded separately")
    }

    /// An append is read from where the last recording stopped. Its turns still belong to the
    /// model and tier announced before the cursor, and a token count re-emitted across the
    /// boundary is still recognised as a replay.
    private static func appendedRolloutResumesWithItsState() {
        let fixture = RecorderFixture(name: "codex-append")
        defer { fixture.remove() }
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol", serviceTier: "priority"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        fixture.record(.codex)
        fixture.appendCodexRollout(Self.rollout, lines: [
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 200, output: 20, total: 330),
        ])
        fixture.record(.codex)
        fixture.record(.codex)

        Harness.expectEqual(
            fixture.recorded(.codex),
            [RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: true): TokenTotals(input: 300, output: 30)],
            "appended turns keep the earlier model and tier and the re-emitted count is skipped"
        )
    }

    /// A rollout rewritten in place is read again from the start, and its earlier rows are
    /// dropped first so its turns are not counted twice.
    private static func rewrittenRolloutIsNotDoubled() {
        let fixture = RecorderFixture(name: "codex-rewrite")
        defer { fixture.remove() }
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        fixture.record(.codex)
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-luna"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 50, output: 5, total: 165),
        ])
        fixture.record(.codex)

        Harness.expectEqual(
            fixture.recorded(.codex),
            [RecordedTier(model: "gpt-5.6-luna", longContext: false, isFast: false): TokenTotals(input: 150, output: 15)],
            "a rewritten rollout is recorded from its new contents only"
        )
    }

    /// Only the first 64KB of a rollout are fingerprinted. A rollout replaced by a new file whose
    /// first 64KB match is still a rewrite, so its changed turns replace the old ones.
    private static func replacedRolloutWithTheSamePrefixIsReparsed() {
        let fixture = RecorderFixture(name: "codex-replace")
        defer { fixture.remove() }
        let prefix = [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            #"{"type":"response_item","padding":"\#(String(repeating: "x", count: 70_000))"}"#,
        ]
        fixture.writeCodexRollout(Self.rollout, lines: prefix + [CodexLine.tokenCount(input: 100, output: 10, total: 110)])
        fixture.record(.codex)
        fixture.writeCodexRollout(Self.rollout, lines: prefix + [CodexLine.tokenCount(input: 200, output: 20, total: 220)])
        fixture.record(.codex)

        Harness.expectEqual(
            fixture.recorded(.codex),
            [RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false): TokenTotals(input: 200, output: 20)],
            "a replaced rollout is reparsed even when its first 64KB are unchanged"
        )
    }

    /// A rollout without a session id that is emptied in place keeps none of the rows recorded
    /// from its old contents. (A shrunken rollout with a session id is taken for a stale copy of
    /// that session and skipped, so its usage is retained.)
    private static func emptiedRolloutKeepsNoRows() {
        let fixture = RecorderFixture(name: "codex-empty")
        defer { fixture.remove() }
        let unnamed = "rollout.jsonl"
        fixture.writeCodexRollout(unnamed, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        fixture.record(.codex)
        Harness.expect(!fixture.recorded(.codex).isEmpty, "the rollout is recorded before it is emptied")
        try? Data().write(to: fixture.codexRollout(unnamed), options: .atomic)
        fixture.record(.codex)

        Harness.expect(fixture.recorded(.codex).isEmpty, "an emptied rollout keeps no recorded rows")
    }

    /// The Long-context tier is settled per turn, so a large turn does not pull a small one of the
    /// same model above the threshold, and a vendor-prefixed name lands on the same model.
    private static func longContextIsSettledPerTurn() {
        let fixture = RecorderFixture(name: "codex-long-context")
        defer { fixture.remove() }
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "openai/codex-tier"),
            CodexLine.tokenCount(input: 150_000, output: 10, total: 150_010),
            CodexLine.turnContext(model: "codex-tier"),
            CodexLine.tokenCount(input: 250_000, output: 10, total: 400_020),
        ])
        let rateCard = RateCard(overrides: [
            "codex-tier": ModelPricing(input: 1, output: 1, thresholdTokens: 200_000, inputAbove: 2, outputAbove: 2),
        ])

        fixture.record(.codex, rateCard: rateCard)

        Harness.expectEqual(
            fixture.recorded(.codex),
            [
                RecordedTier(model: "codex-tier", longContext: false, isFast: false): TokenTotals(input: 150_000, output: 10),
                RecordedTier(model: "codex-tier", longContext: true, isFast: false): TokenTotals(input: 250_000, output: 10),
            ],
            "each turn lands in its own tier, under the model ID its vendor-prefixed name resolves to"
        )
    }
}

/// Rollout lines in the shape Codex writes them.
enum CodexLine {
    static func turnContext(model: String, serviceTier: String? = nil) -> String {
        let tier = serviceTier.map { #","service_tier":"\#($0)""# } ?? ""
        return #"{"type":"turn_context","timestamp":"2026-09-01T12:00:00Z","payload":{"model":"\#(model)"\#(tier)}}"#
    }

    /// A turn's delta. `total` stands in for the running `total_token_usage`, which is what tells
    /// a new turn from a re-emitted one.
    static func tokenCount(
        input: Int,
        cached: Int = 0,
        cacheWrite: Int = 0,
        output: Int,
        total: Int,
        timestamp: String = "2026-09-01T12:00:00Z"
    ) -> String {
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output)},"total_token_usage":{"total_tokens":\#(total)}}}}"#
    }
}

extension RecorderFixture {
    func codexRollout(_ relativePath: String) -> URL {
        self.root.appendingPathComponent("codex/sessions").appendingPathComponent(relativePath)
    }

    func writeCodexRollout(_ relativePath: String, lines: [String]) {
        let file = self.codexRollout(relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func appendCodexRollout(_ relativePath: String, lines: [String]) {
        guard let handle = try? FileHandle(forWritingTo: self.codexRollout(relativePath)) else {
            Harness.expect(false, "could not append to \(relativePath)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
