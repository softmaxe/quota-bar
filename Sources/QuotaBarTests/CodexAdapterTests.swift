import QuotaBarCore
import Foundation

/// Rollout lines in, observed requests out, with no database.
enum CodexAdapterTests {
    static func run() {
        Self.cacheBucketsArePeeledOutOfInput()
        Self.replayedTokenCountsAreSkipped()
        Self.turnContextCarriesAcrossParsers()
        Self.rolloutsWithoutTurnContextHaveNoModel()
    }

    private static let adapter = CodexAdapter(env: [:])
    private static let file = URL(fileURLWithPath: "/dev/null")

    private static func requests(
        _ lines: [String],
        savedState: String? = nil
    ) -> (requests: [ObservedRequest], savedState: String?) {
        var parser = Self.adapter.parser(for: Self.file, resumingAt: 0, savedState: savedState)
        let requests = lines.compactMap { line in
            Data(line.utf8).withUnsafeBytes { parser.request(in: $0) }
        }
        return (requests, parser.savedState)
    }

    /// Codex counts cached reads and cache writes inside input_tokens; each bucket is priced once.
    private static func cacheBucketsArePeeledOutOfInput() {
        let observed = Self.requests([
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 1_000, cached: 600, cacheWrite: 300, output: 50, total: 1_050),
        ]).requests
        Harness.expectEqual(
            observed.first?.tokens,
            TokenTotals(input: 100, output: 50, cacheWrite: 300, cacheRead: 600),
            "cached reads and cache writes are carved out of input"
        )
        Harness.expectEqual(observed.first?.key, nil, "a Codex turn has no dedupe key")
        Harness.expectEqual(observed.first?.model, "gpt-5.6-sol", "the model is reported as the log spelled it")
    }

    /// Codex re-emits the last token count when only the rate-limit block changed. The running
    /// total standing still is what marks it as a replay.
    private static func replayedTokenCountsAreSkipped() {
        let observed = Self.requests([
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 100, output: 10, total: 220),
        ]).requests
        Harness.expectEqual(observed.count, 2, "a re-emitted token count is not a new turn")
    }

    /// A later parser resumed from the saved state knows the model, the service tier, and the
    /// last running total from lines it never sees.
    private static func turnContextCarriesAcrossParsers() {
        let first = Self.requests([
            CodexLine.turnContext(model: "gpt-5.6-sol", serviceTier: "priority"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        let resumed = Self.requests([
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
            CodexLine.tokenCount(input: 200, output: 20, total: 330),
        ], savedState: first.savedState).requests

        Harness.expectEqual(resumed.count, 1, "the re-emitted count across the boundary is skipped")
        Harness.expectEqual(resumed.first?.model, "gpt-5.6-sol", "the resumed turn keeps the earlier model")
        Harness.expectEqual(resumed.first?.isFast, true, "the resumed turn keeps the earlier priority tier")
    }

    /// Rollouts written before Codex logged turn_context still count, with no model to price.
    private static func rolloutsWithoutTurnContextHaveNoModel() {
        let observed = Self.requests([CodexLine.tokenCount(input: 100, output: 10, total: 110)]).requests
        Harness.expectEqual(observed.count, 1, "a turn before any turn context is still a request")
        Harness.expectEqual(observed.first?.model, nil, "a turn before any turn context has no model")
    }
}
