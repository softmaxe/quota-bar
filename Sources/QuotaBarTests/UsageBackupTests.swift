@testable import QuotaBarApp
import QuotaBarCore
import Foundation

/// A backup and its import, through the same service the app calls: what a new install gets back,
/// and what importing must never do to the usage already there.
enum UsageBackupTests {
    static func run() async {
        await Self.exportRestoresUsageWhoseLogsAreGone()
        await Self.exportReplacesAnEarlierBackupAtThatPath()
        await Self.olderBackupRemovesNothing()
        await Self.importingTwiceAddsNothing()
        await Self.claudeKeepsTheFinishedMessage()
        await Self.codexKeepsTheFurtherScan()
        await Self.restoredCodexRolloutResumes()
        await Self.sessionUnderAnotherPathCountsOnce()
        await Self.importKeepsTheDatabaseAsItStood()
        await Self.legacyBackupIsUpgraded()
        await Self.unusableFilesChangeNothing()
        await Self.settingsPaneReportsEachOutcome()
    }

    private static let rollout = "2026/09/01/rollout-2026-09-01T12-00-00-0199a000-0000-7000-8000-000000000002.jsonl"
    private static let codexTier = RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)
    private static let claudeTier = RecordedTier(model: "claude-opus-5", longContext: false, isFast: false)

    /// The case the feature exists for: the logs and the app's data are both gone.
    private static func exportRestoresUsageWhoseLogsAreGone() async {
        let original = BackupFixture(name: "restore-original")
        let restored = BackupFixture(name: "restore-new")
        defer { original.remove(); restored.remove() }
        original.logs.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        original.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 7, output: 3),
        ])
        await original.scan()
        await Self.export(original)
        try? FileManager.default.removeItem(at: original.logs.root.appendingPathComponent("codex"))
        try? FileManager.default.removeItem(at: original.logs.root.appendingPathComponent("claude"))

        Harness.expect(
            FileManager.default.fileExists(atPath: original.backup.path),
            "the export wrote a file at the chosen path"
        )
        let result = await Self.importBackup(original.backup, into: restored)
        await restored.scan()

        Harness.expectEqual(result?.added, 2, "both records are reported as added")
        Harness.expectEqual(restored.logs.recorded(.codex)[Self.codexTier]?.input, 100, "Codex usage is back")
        Harness.expectEqual(restored.logs.recorded(.claude)[Self.claudeTier]?.input, 7, "Claude usage is back")
        Harness.expectEqual(
            (try? CostUsageReader.savedUsage(databaseURL: restored.logs.databaseURL))?.records,
            2,
            "the saved-usage summary counts what was restored"
        )
    }

    /// An export may land where an earlier backup sits, and the new one has to take its place.
    private static func exportReplacesAnEarlierBackupAtThatPath() async {
        let fixture = BackupFixture(name: "replace")
        defer { fixture.remove() }
        fixture.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 7, output: 3),
        ])
        try? Data("an earlier backup".utf8).write(to: fixture.backup)
        await fixture.scan()
        await Self.export(fixture)

        Harness.expectEqual(
            (try? CostUsageReader.savedUsage(databaseURL: fixture.backup))?.records,
            1,
            "the export replaced the file already at that path"
        )
    }

    /// Records made after a backup, whose logs have since gone, survive importing that backup.
    private static func olderBackupRemovesNothing() async {
        let fixture = BackupFixture(name: "older")
        defer { fixture.remove() }
        fixture.logs.writeClaudeTranscript("app/early.jsonl", lines: [
            ClaudeLine.assistant(id: "early", model: "claude-opus-5", input: 1, output: 1),
        ])
        await fixture.scan()
        await Self.export(fixture)

        fixture.logs.writeClaudeTranscript("app/late.jsonl", lines: [
            ClaudeLine.assistant(id: "late", model: "claude-opus-5", input: 10, output: 1),
        ])
        await fixture.scan()
        try? FileManager.default.removeItem(at: fixture.logs.claudeTranscript("app/late.jsonl"))
        let result = await Self.importBackup(fixture.backup, into: fixture)

        Harness.expectEqual(result, UsageImportResult(added: 0, updated: 0), "an older backup has nothing to add")
        Harness.expectEqual(
            fixture.logs.recorded(.claude)[Self.claudeTier]?.input,
            11,
            "usage recorded after the backup is still there"
        )
    }

    private static func importingTwiceAddsNothing() async {
        let original = BackupFixture(name: "twice-original")
        let restored = BackupFixture(name: "twice-new")
        defer { original.remove(); restored.remove() }
        original.logs.writeCodexRollout(Self.rollout, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        original.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 7, output: 3),
        ])
        await original.scan()
        await Self.export(original)

        _ = await Self.importBackup(original.backup, into: restored)
        let second = await Self.importBackup(original.backup, into: restored)

        Harness.expectEqual(second, UsageImportResult(added: 0, updated: 0), "a second import changes nothing")
        Harness.expectEqual(restored.logs.recorded(.codex)[Self.codexTier]?.input, 100, "Codex usage is not doubled")
        Harness.expectEqual(restored.logs.recorded(.claude)[Self.claudeTier]?.input, 7, "Claude usage is not doubled")
    }

    /// The same message on both sides follows the recording rule: the larger output is final.
    private static func claudeKeepsTheFinishedMessage() async {
        let backup = BackupFixture(name: "claude-backup")
        let local = BackupFixture(name: "claude-local")
        defer { backup.remove(); local.remove() }
        backup.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "grew", model: "claude-opus-5", input: 1, output: 50),
            ClaudeLine.assistant(id: "shrank", model: "claude-opus-5", input: 1, output: 5),
        ])
        local.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "grew", model: "claude-opus-5", input: 1, output: 5),
            ClaudeLine.assistant(id: "shrank", model: "claude-opus-5", input: 1, output: 50),
        ])
        await backup.scan()
        await local.scan()
        await Self.export(backup)

        let result = await Self.importBackup(backup.backup, into: local)

        Harness.expectEqual(result, UsageImportResult(added: 0, updated: 1), "only the shorter message is updated")
        Harness.expectEqual(
            local.logs.recorded(.claude)[Self.claudeTier]?.output,
            100,
            "each message keeps its larger output"
        )
    }

    /// A rollout's rows are one running total, so the further scan replaces the other, and the
    /// two are never added together.
    private static func codexKeepsTheFurtherScan() async {
        let behind = BackupFixture(name: "codex-behind")
        let ahead = BackupFixture(name: "codex-ahead")
        defer { behind.remove(); ahead.remove() }
        let path = "/shared/\(Self.rollout)"
        for (fixture, input, offset) in [(behind, 100, 50), (ahead, 300, 150)] {
            await fixture.scan()
            fixture.seedCodexRollout(path: path, input: input, offset: offset)
        }
        await Self.export(ahead)
        await Self.export(behind)

        let forward = await Self.importBackup(ahead.backup, into: behind)
        Harness.expectEqual(forward, UsageImportResult(added: 0, updated: 1), "the further scan is an update")
        Harness.expectEqual(behind.logs.recorded(.codex)[Self.codexTier]?.input, 300, "the further scan replaces the rows")

        let backward = await Self.importBackup(behind.backup, into: ahead)
        Harness.expectEqual(backward, UsageImportResult(added: 0, updated: 0), "a scan behind changes nothing")
        Harness.expectEqual(ahead.logs.recorded(.codex)[Self.codexTier]?.input, 300, "the further scan is kept")
    }

    /// A restored disk gives the rollout a new inode. Whatever it reappears as, what it appended
    /// counts and nothing counts twice.
    private static func restoredCodexRolloutResumes() async {
        let original = BackupFixture(name: "resume-original")
        let restored = BackupFixture(name: "resume-new")
        defer { original.remove(); restored.remove() }
        let lines = [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ]
        restored.logs.writeCodexRollout(Self.rollout, lines: lines)
        await restored.scan()
        await Self.export(restored)
        // A new file in the same place, as a restore writes it, on a database that lost its rows.
        try? FileManager.default.removeItem(at: restored.logs.databaseURL)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: restored.logs.databaseURL.path + suffix)
        }
        restored.logs.writeCodexRollout(Self.rollout, lines: lines)
        let fresh = BackupFixture(name: "resume-new", keeping: restored.logs)

        _ = await Self.importBackup(restored.backup, into: fresh)
        await fresh.scan()
        Harness.expectEqual(fresh.logs.recorded(.codex)[Self.codexTier]?.input, 100, "the restored rollout is not doubled")

        restored.logs.appendCodexRollout(Self.rollout, lines: [
            CodexLine.tokenCount(input: 200, output: 20, total: 330),
        ])
        await fresh.scan()
        Harness.expectEqual(fresh.logs.recorded(.codex)[Self.codexTier]?.input, 300, "what it appended is added")
    }

    /// The backup came from another Mac, so the same session sits under another home directory.
    private static func sessionUnderAnotherPathCountsOnce() async {
        let local = BackupFixture(name: "paths-local")
        let remote = BackupFixture(name: "paths-remote")
        defer { local.remove(); remote.remove() }
        let lines = [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ]
        local.logs.writeCodexRollout(Self.rollout, lines: lines)
        await local.scan()
        await remote.scan()
        remote.seedCodexRollout(path: "/Users/elsewhere/.codex/sessions/\(Self.rollout)", input: 100, offset: 40)
        await Self.export(remote)

        _ = await Self.importBackup(remote.backup, into: local)
        await local.scan()

        Harness.expectEqual(local.logs.recorded(.codex)[Self.codexTier]?.input, 100, "one session counts once")
    }

    private static func importKeepsTheDatabaseAsItStood() async {
        let original = BackupFixture(name: "undo-original")
        let local = BackupFixture(name: "undo-local")
        defer { original.remove(); local.remove() }
        original.logs.writeClaudeTranscript("app/new.jsonl", lines: [
            ClaudeLine.assistant(id: "new", model: "claude-opus-5", input: 7, output: 3),
        ])
        local.logs.writeClaudeTranscript("app/old.jsonl", lines: [
            ClaudeLine.assistant(id: "old", model: "claude-opus-5", input: 1, output: 1),
        ])
        await original.scan()
        await local.scan()
        await Self.export(original)

        _ = await Self.importBackup(original.backup, into: local)

        Harness.expectEqual(
            (try? CostUsageReader.savedUsage(databaseURL: local.service.undoCopyURL))?.records,
            1,
            "the database as it stood before the import is kept"
        )
    }

    private static func legacyBackupIsUpgraded() async {
        let fixture = BackupFixture(name: "legacy")
        defer { fixture.remove() }
        let legacy = fixture.logs.root.appendingPathComponent("legacy.sqlite")
        do {
            try TestDatabase(legacy).exec("""
                CREATE TABLE file_cursor (
                    path TEXT PRIMARY KEY, provider TEXT NOT NULL, inode INTEGER NOT NULL,
                    size INTEGER NOT NULL, offset INTEGER NOT NULL, prefix_digest TEXT NOT NULL
                );
                CREATE TABLE codex_day (
                    path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
                    long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL, cost_usd REAL,
                    PRIMARY KEY (path, day, model, long_context)
                );
                CREATE TABLE claude_message (
                    key TEXT PRIMARY KEY, path TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
                    long_context INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL, cost_usd REAL
                );
                CREATE TABLE opencode_state (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                INSERT INTO claude_message VALUES (
                    'legacy', '/gone.jsonl', '2026-01-01', 'claude-opus-5', 0, 7, 3, 0, 0, 0.5
                );
                """)
        } catch {
            Harness.expect(false, "could not write the legacy backup: \(error)")
        }

        _ = await Self.importBackup(legacy, into: fixture)

        Harness.expectEqual(fixture.logs.recorded(.claude)[Self.claudeTier]?.input, 7, "a legacy backup's usage is imported")
        Harness.expect(
            ((try? TestDatabase(legacy, readOnly: true).scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('claude_message') WHERE name = 'cost_usd'"
            )) ?? 0) == 1,
            "the chosen file itself is left as it was"
        )
    }

    /// Each of these leaves the saved usage exactly as it was and says why.
    private static func unusableFilesChangeNothing() async {
        let fixture = BackupFixture(name: "unusable")
        defer { fixture.remove() }
        fixture.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 7, output: 3),
        ])
        await fixture.scan()

        let text = fixture.logs.root.appendingPathComponent("notes.sqlite")
        try? Data(String(repeating: "not a database\n", count: 200).utf8).write(to: text)
        let foreign = fixture.logs.root.appendingPathComponent("foreign.sqlite")
        try? TestDatabase(foreign).exec("CREATE TABLE notes (body TEXT)")
        let newer = fixture.logs.root.appendingPathComponent("newer.sqlite")
        await Self.export(fixture, to: newer)
        try? TestDatabase(newer).exec("ALTER TABLE claude_message ADD COLUMN from_the_future INTEGER")

        await Self.expectRefused(text, by: fixture, "a file that is not a database")
        await Self.expectRefused(foreign, by: fixture, "another app's database")
        await Self.expectRefused(newer, by: fixture, "a backup from a newer version")
        await Self.expectRefused(
            fixture.logs.root.appendingPathComponent("missing.sqlite"), by: fixture, "a file that is gone"
        )

        Harness.expectEqual(fixture.logs.recorded(.claude)[Self.claudeTier]?.input, 7, "the saved usage is untouched")
    }

    /// What the pane does around the service: the message it shows and the scan that puts imported
    /// usage on the card.
    @MainActor
    private static func settingsPaneReportsEachOutcome() async {
        let fixture = BackupFixture(name: "pane")
        defer { fixture.remove() }
        let suite = "QuotaBarBackupTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.logs.writeClaudeTranscript("app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "msg", model: "claude-opus-5", input: 7, output: 3),
        ])
        await fixture.scan()

        var scans = 0
        let settings = SettingsStore(defaults: defaults)
        let store = UsageStore(
            settings: settings,
            costService: fixture.service,
            fetchState: { _, _ in .signedOut("") },
            fetchCost: { _ in
                scans += 1
                return nil
            },
            updateThirdPartyRates: { false },
            historyStore: UsageHistoryStore(fileURL: fixture.logs.root.appendingPathComponent("history.json")),
            recoveryDefaults: defaults
        )
        let model = UsageBackupModel(store: store)

        await model.loadSummary()
        Harness.expectEqual(model.summary?.records, 1, "the pane reads what is saved")

        await model.exportBackup(to: fixture.backup)
        Harness.expectEqual(model.outcome, .exported(fileName: "backup.sqlite"), "the pane names the file it saved")

        let text = fixture.logs.root.appendingPathComponent("notes.sqlite")
        try? Data(String(repeating: "not a database\n", count: 200).utf8).write(to: text)
        await model.importBackup(from: text)
        Harness.expectEqual(
            model.outcome,
            .failed(UsageBackupError.unreadable.localizedDescription),
            "the pane says why a file was refused"
        )
        Harness.expectEqual(scans, 0, "a refused file starts no scan")

        await model.importBackup(from: fixture.backup)
        Harness.expectEqual(
            model.outcome,
            .imported(UsageImportResult(added: 0, updated: 0)),
            "the pane reports what the import changed"
        )
        let deadline = Date().addingTimeInterval(5)
        while scans < Provider.allCases.count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        Harness.expectEqual(scans, Provider.allCases.count, "an import scans every provider")
    }

    private static func expectRefused(_ file: URL, by fixture: BackupFixture, _ label: String) async {
        do {
            _ = try await fixture.service.importBackup(from: file)
            Harness.expect(false, "\(label) was imported")
        } catch {
            Harness.expect(true, "\(label) was refused")
        }
    }

    private static func export(_ fixture: BackupFixture, to url: URL? = nil) async {
        do {
            try await fixture.service.exportBackup(to: url ?? fixture.backup)
        } catch {
            Harness.expect(false, "export \(fixture.logs.root.lastPathComponent) threw: \(error)")
        }
    }

    private static func importBackup(_ url: URL, into fixture: BackupFixture) async -> UsageImportResult? {
        do {
            return try await fixture.service.importBackup(from: url)
        } catch {
            Harness.expect(false, "import into \(fixture.logs.root.lastPathComponent) threw: \(error)")
            return nil
        }
    }
}

/// A service on a temporary log root, as the app holds one, and where its backups go.
private struct BackupFixture {
    let logs: RecorderFixture
    let service: CostService

    init(name: String) {
        self.init(name: "backup-\(name)", keeping: RecorderFixture(name: "backup-\(name)"))
    }

    /// A service starting over on the logs of an earlier fixture.
    init(name _: String, keeping logs: RecorderFixture) {
        self.logs = logs
        self.service = CostService(databaseURL: logs.databaseURL, env: logs.env, rateCard: RateCard())
    }

    var backup: URL { self.logs.root.appendingPathComponent("backup.sqlite") }

    func scan() async {
        _ = await self.service.refresh(.codex)
        _ = await self.service.refresh(.claude)
    }

    /// A rollout recorded at `offset`, without the log behind it.
    func seedCodexRollout(path: String, input: Int, offset: Int) {
        do {
            let database = try TestDatabase(self.logs.databaseURL)
            try database.exec("""
                INSERT INTO codex_day
                    (path, day, model, long_context, is_fast, input, output, cache_write,
                     cache_write_1h, cache_read)
                VALUES (?, '2026-09-01', 'gpt-5.6-sol', 0, 0, \(input), 10, 0, 0, 0)
                """, path)
            try database.exec("""
                INSERT INTO file_cursor (path, provider, inode, size, offset, prefix_digest)
                VALUES (?, 'codex', 7, \(offset), \(offset), 'digest')
                """, path)
        } catch {
            Harness.expect(false, "could not seed a rollout: \(error)")
        }
    }

    func remove() { self.logs.remove() }
}
