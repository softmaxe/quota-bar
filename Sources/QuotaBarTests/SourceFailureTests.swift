import QuotaBarCore
import Foundation
import SQLite3

/// One failing Usage source must not hide the others: its previously recorded usage keeps
/// counting, its scan status reports the failure, and the refresh still returns a snapshot.
enum SourceFailureTests {
    static func run() async {
        await Self.failedCodexScanKeepsOtherSourcesRecording()
        await Self.failedCodexScanStillYieldsASnapshot()
        await Self.failedClaudeScanKeepsRecordedUsage()
        await Self.databaseOpenFailureYieldsNoSnapshot()
    }

    private static let rollout = "2026/09/01/rollout-2026-09-01T12-00-00-0199a000-0000-7000-8000-000000000103.jsonl"

    /// The Codex scan fails while OpenCode and Pi Agent read fine: their usage is recorded, the
    /// Codex usage recorded before stays, and Codex's scan status reports the failure.
    private static func failedCodexScanKeepsOtherSourcesRecording() async {
        let fixture = RecorderFixture(name: "failure-codex")
        defer { fixture.remove() }
        await Self.recordCodexThenBreakIt(fixture) { fixture.record(.codex) }
        Self.writeExternalAgentUsage(fixture)

        fixture.record(.codex)

        let usage = fixture.recorded(.codex)
        Harness.expectEqual(
            usage[RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)]?.input,
            100,
            "Codex usage recorded before the failure still counts"
        )
        Harness.expectEqual(
            usage[RecordedTier(model: "gpt-5.6-luna", longContext: false, isFast: false)]?.input,
            10,
            "OpenCode usage is recorded although the Codex scan failed"
        )
        Harness.expectEqual(
            usage[RecordedTier(model: "gpt-5.6-terra", longContext: false, isFast: false)]?.input,
            5,
            "Pi Agent usage is recorded although the Codex scan failed"
        )
        Harness.expectEqual(fixture.recorder?.scanStatus(of: .codex), .error("database"), "Codex scan status reports the failure")
        Harness.expectEqual(fixture.recorder?.scanStatus(of: .openCode), .idle, "OpenCode status is unaffected")
    }

    /// The Codex refresh still returns a cost snapshot when the Codex scan fails, and it shows
    /// OpenCode, Pi Agent, and the Codex usage recorded before.
    private static func failedCodexScanStillYieldsASnapshot() async {
        let fixture = RecorderFixture(name: "failure-codex-refresh")
        defer { fixture.remove() }
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: RateCard())
        await Self.recordCodexThenBreakIt(fixture) { _ = await service.refresh(.codex) }
        Self.writeExternalAgentUsage(fixture)

        let snapshot = await service.refresh(.codex)

        Harness.expect(snapshot != nil, "a Codex scan failure still yields a snapshot")
        let tokens = Self.inputTokens(bySourceIn: snapshot)
        Harness.expectEqual(tokens[.codex], 100, "the snapshot keeps previously recorded Codex usage")
        Harness.expectEqual(tokens[.openCode], 10, "the snapshot shows OpenCode usage")
        Harness.expectEqual(tokens[.piAgent], 5, "the snapshot shows Pi Agent usage")
    }

    /// The Claude Code scan fails because another writer holds the database: the refresh still
    /// returns the Claude Code usage recorded before, and the scan status reports the failure.
    private static func failedClaudeScanKeepsRecordedUsage() async {
        let fixture = RecorderFixture(name: "failure-claude")
        defer { fixture.remove() }
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: RateCard())
        let path = "app/session.jsonl"
        fixture.writeClaudeTranscript(path, lines: [
            ClaudeLine.assistant(id: "one", model: "claude-opus-5", input: 70, output: 7, timestamp: Self.now),
        ])
        _ = await service.refresh(.claude)
        fixture.appendClaudeTranscript(path, lines: [
            ClaudeLine.assistant(id: "two", model: "claude-opus-5", input: 30, output: 3, timestamp: Self.now),
        ])

        guard let writer = RawDatabase(fixture.databaseURL) else { return }
        writer.exec("BEGIN IMMEDIATE")
        let snapshot = await service.refresh(.claude)
        fixture.record(.claude)
        writer.exec("ROLLBACK")
        writer.close()

        Harness.expect(snapshot != nil, "a Claude Code scan failure still yields a snapshot")
        Harness.expectEqual(
            Self.inputTokens(bySourceIn: snapshot)[.claude],
            70,
            "the snapshot keeps previously recorded Claude Code usage"
        )
        Harness.expectEqual(
            fixture.recorder?.scanStatus(of: .claude),
            .error("database"),
            "Claude Code scan status reports the failure"
        )
    }

    /// A database that cannot open affects every source, so the refresh yields no snapshot.
    private static func databaseOpenFailureYieldsNoSnapshot() async {
        let fixture = RecorderFixture(name: "failure-open")
        defer { fixture.remove() }
        let blocker = fixture.root.appendingPathComponent("blocker")
        try? Data("not a directory".utf8).write(to: blocker)
        let service = CostService(
            databaseURL: blocker.appendingPathComponent("usage.sqlite"),
            env: fixture.env,
            rateCard: RateCard()
        )

        let snapshot = await service.refresh(.codex)

        Harness.expect(snapshot == nil, "a database open failure yields no snapshot")
    }

    /// Records one Codex rollout, then deletes it and makes every Codex cursor write fail, so the
    /// next Codex scan throws while noting the deletion.
    private static func recordCodexThenBreakIt(_ fixture: RecorderFixture, record: () async -> Void) async {
        fixture.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110, timestamp: Self.now),
        ])
        await record()
        try? FileManager.default.removeItem(at: fixture.codexRollout(Self.rollout))
        guard let db = RawDatabase(fixture.databaseURL) else { return }
        db.exec("""
            CREATE TRIGGER fail_codex_cursor BEFORE INSERT ON file_cursor WHEN NEW.provider = 'codex'
            BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END
            """)
        db.close()
    }

    /// OpenCode usage of 10 input tokens and Pi Agent usage of 5, both of the Codex account.
    private static func writeExternalAgentUsage(_ fixture: RecorderFixture) {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        PiSessionFile.signIn(root: fixture.root, piAccount: "account-a")
        PiSessionFile.write(root: fixture.root, "project/session.jsonl", lines: [
            PiSessionFile.message("one", model: "gpt-5.6-terra", milliseconds: milliseconds, input: 5),
        ])
        guard let db = OpenCodeFixtureDatabase(at: fixture.root) else { return }
        db.stepFinish("part-1", created: milliseconds, model: "gpt-5.6-luna", input: 10)
        db.close()
        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: db.url.deletingLastPathComponent().appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
    }

    private static var now: String { ISO8601DateFormatter().string(from: Date()) }

    private static func inputTokens(bySourceIn snapshot: CostSnapshot?) -> [CostUsageSource: Int] {
        var totals: [CostUsageSource: Int] = [:]
        for day in snapshot?.days ?? [] {
            for (key, usage) in day.byModel { totals[key.source, default: 0] += usage.tokens.input }
        }
        return totals
    }
}

/// A second connection to a recorder's database, standing in for a fault outside the recorder.
private final class RawDatabase {
    private var db: OpaquePointer?

    init?(_ url: URL) {
        guard sqlite3_open(url.path, &self.db) == SQLITE_OK else {
            Harness.expect(false, "raw database connection opens")
            sqlite3_close(self.db)
            return nil
        }
    }

    func exec(_ sql: String) {
        Harness.expect(sqlite3_exec(self.db, sql, nil, nil, nil) == SQLITE_OK, "raw SQL runs: \(sql)")
    }

    func close() {
        sqlite3_close(self.db)
    }
}
