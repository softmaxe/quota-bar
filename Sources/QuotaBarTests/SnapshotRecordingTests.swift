import QuotaBarCore
import Foundation

/// The Usage recorder's whole-snapshot read mode: a source read whole each pass, skipped while
/// its stat snapshot is unchanged, and flagged by one `included` value per batch.
enum SnapshotRecordingTests {
    static func run() {
        Self.unchangedSnapshotIsSkipped()
        Self.changedSnapshotRewritesChangedRows()
        Self.eligibleAccountIsIncluded()
        Self.ineligibleAccountIsRecordedButNotIncluded()
    }

    private static let standard = RecordedTier(model: "gpt-5.6-luna", longContext: false, isFast: false)

    /// While the source's snapshot is unchanged its contents are not read again, so a refresh
    /// stays cheap however much history the source holds.
    private static func unchangedSnapshotIsSkipped() {
        let fixture = RecorderFixture(name: "snapshot-skip")
        defer { fixture.remove() }

        let first = fixture.recorder?.record(FakeSnapshotAdapter(stamp: 1, batch: [.part("a", input: 10)]), rateCard: RateCard())
        let second = fixture.recorder?.record(FakeSnapshotAdapter(stamp: 1, batch: [.part("a", input: 99)]), rateCard: RateCard())

        Harness.expectEqual(first, 1, "a new snapshot is read whole")
        Harness.expectEqual(second, 0, "an unchanged snapshot is skipped")
        Harness.expectEqual(
            fixture.recorded(.codex)[Self.standard]?.input,
            10,
            "contents behind an unchanged snapshot are not reread"
        )
    }

    /// A changed snapshot is reread whole. Each row is kept once per key and rewritten only when
    /// its content changed, so rereading the same rows cannot double them.
    private static func changedSnapshotRewritesChangedRows() {
        let fixture = RecorderFixture(name: "snapshot-change")
        defer { fixture.remove() }

        fixture.recorder?.record(FakeSnapshotAdapter(stamp: 1, batch: [.part("a", input: 10)]), rateCard: RateCard())
        fixture.recorder?.record(
            FakeSnapshotAdapter(stamp: 2, batch: [.part("a", input: 30), .part("b", input: 5)]),
            rateCard: RateCard()
        )

        Harness.expectEqual(
            fixture.recorded(.codex)[Self.standard]?.input,
            35,
            "a changed snapshot rewrites a grown row and adds a new one, once each"
        )
    }

    /// OpenCode usage counts when OpenCode is signed in with OAuth to the account Codex uses.
    private static func eligibleAccountIsIncluded() {
        let fixture = RecorderFixture(name: "snapshot-eligible")
        defer { fixture.remove() }
        Self.writeOpenCodeUsage(fixture, openCodeAccount: "account-a")

        fixture.recorder?.record(OpenCodeAdapter(env: fixture.env), rateCard: RateCard())

        Harness.expectEqual(fixture.recorded(.codex)[Self.standard]?.input, 10, "an eligible account's usage is included")
        Harness.expectEqual(fixture.recorder?.scanStatus(of: .openCode), .idle, "an eligible account is quiet")
    }

    /// Usage signed in to another account is someone else's, so it is not counted, and the scan
    /// status says why.
    private static func ineligibleAccountIsRecordedButNotIncluded() {
        let fixture = RecorderFixture(name: "snapshot-ineligible")
        defer { fixture.remove() }
        Self.writeOpenCodeUsage(fixture, openCodeAccount: "account-b")

        fixture.recorder?.record(OpenCodeAdapter(env: fixture.env), rateCard: RateCard())

        Harness.expect(fixture.recorded(.codex).isEmpty, "an ineligible account's usage is not included")
        Harness.expectEqual(
            fixture.recorder?.scanStatus(of: .openCode),
            .accountMismatch,
            "an ineligible account reports the mismatch"
        )
    }

    private static func writeOpenCodeUsage(_ fixture: RecorderFixture, openCodeAccount: String) {
        let codex = fixture.root.appendingPathComponent("codex")
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try? #"{"tokens":{"account_id":"account-a"}}"#.write(
            to: codex.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        guard let db = OpenCodeFixtureDatabase(at: fixture.root) else { return }
        db.stepFinish("part-1", created: 1_788_264_000_000, model: "gpt-5.6-luna", input: 10)
        db.close()
        try? #"{"openai":{"type":"oauth","accountId":"\#(openCodeAccount)"}}"#.write(
            to: db.url.deletingLastPathComponent().appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
    }
}

/// A snapshot source whose stamp and contents a check sets directly.
private struct FakeSnapshotAdapter: SnapshotAdapter {
    let stamp: Int
    let batch: [ObservedRequest]

    var source: CostUsageSource { .openCode }
    func survey() -> SnapshotSurvey<Int> { .present(stamp: self.stamp, included: true, status: .idle) }
    func requests() throws -> [ObservedRequest] { self.batch }
}

private extension ObservedRequest {
    static func part(_ key: String, input: Int) -> ObservedRequest {
        ObservedRequest(
            key: key,
            timestamp: Date(timeIntervalSince1970: 1_788_264_000),
            model: "gpt-5.6-luna",
            tokens: TokenTotals(input: input),
            isFast: false
        )
    }
}
