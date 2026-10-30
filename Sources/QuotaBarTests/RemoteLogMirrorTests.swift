import QuotaBarCore
@testable import QuotaBarApp
import Foundation

/// Mirroring other machines' logs: what reaches ssh and rsync, how a failure surfaces, and that
/// mirrored logs count once alongside this Mac's own.
enum RemoteLogMirrorTests {
    static func run() async {
        Self.hostNamesCannotReadAsOptions()
        Self.configHostsLeaveOutPatterns()
        await Self.manualRefreshKeepsHostsManualUntilChanged()
        await Self.syncCopiesOnlyTheDirectoriesTheMachineHas()
        await Self.unreachableMachineCopiesNothing()
        await Self.machineWithoutLogsIsReported()
        await Self.failedCopyReportsItsLastLine()
        Self.sessionsOnBothMachinesCountOnce()
        Self.mirroredLogsResumeWhereTheyStopped()
        Self.hostUsageSeparatesHeldFromNew()
        Self.logsWithoutUsageHoldNoRecords()
        Self.scannedMirrorsAreCountedAfterAnUpgrade()
        Self.restoredBackupKeepsWhatHostsHold()
    }

    private static let rollout = "2026/09/01/rollout-2026-09-01T12-00-00-0199a000-0000-7000-8000-000000000001.jsonl"
    private static let otherRollout = "2026/09/02/rollout-2026-09-02T12-00-00-0199a000-0000-7000-8000-000000000003.jsonl"
    private static let codexLines = [
        CodexLine.turnContext(model: "gpt-5.6-sol"),
        CodexLine.tokenCount(input: 100, output: 10, total: 110),
    ]

    private static func hostNamesCannotReadAsOptions() {
        Harness.expect(RemoteLogMirror.isValidHost("ubuntu-tailscale"), "an alias is a host")
        Harness.expect(RemoteLogMirror.isValidHost("dev@203.0.113.10"), "user and address are a host")
        Harness.expect(!RemoteLogMirror.isValidHost("-oProxyCommand=touch"), "an option is not a host")
        Harness.expect(!RemoteLogMirror.isValidHost("host name"), "a space splits a host")
        Harness.expect(!RemoteLogMirror.isValidHost("host:path"), "a colon reads as an rsync path")
        Harness.expect(!RemoteLogMirror.isValidHost("../host"), "a path cannot escape the mirror")
    }

    private static func configHostsLeaveOutPatterns() {
        let config = """
        Host ubuntu-tailscale
            HostName 203.0.113.10
          host vmiss vmiss-tailscale
        Host *.example.com !nope *
        # Host commented
        Host ubuntu-tailscale
        """
        Harness.expectEqual(
            SSHConfigHosts.parse(config),
            ["ubuntu-tailscale", "vmiss", "vmiss-tailscale"],
            "only named hosts are offered, once each"
        )
    }

    /// Hosts used to follow the refresh cadence, so someone on Manual must not start connecting.
    @MainActor
    private static func manualRefreshKeepsHostsManualUntilChanged() {
        let defaults = EphemeralDefaults.make("QuotaBarRemoteAutoSyncTests")
        Harness.expect(SettingsStore(defaults: defaults).remoteAutoSync, "hosts sync on their own by default")

        defaults.set(RefreshFrequency.manual.rawValue, forKey: "refreshFrequency")
        let manual = SettingsStore(defaults: defaults)
        Harness.expect(!manual.remoteAutoSync, "Manual refresh starts with automatic sync off")

        manual.remoteAutoSync = true
        Harness.expect(SettingsStore(defaults: defaults).remoteAutoSync, "the saved choice outlives Manual refresh")
    }

    /// `ls` lists what exists and exits nonzero for the rest, which is not a failure.
    private static func syncCopiesOnlyTheDirectoriesTheMachineHas() async {
        let fixture = RecorderFixture(name: "remote-sync")
        defer { fixture.remove() }
        let commands = CommandLog(replies: [
            CommandOutput(status: 2, stdout: ".claude/projects\n.codex/sessions\n", stderr: "ls: no such file"),
            CommandOutput(status: 0),
            CommandOutput(status: 0),
        ])
        let root = fixture.root.appendingPathComponent("remote logs")
        let mirror = RemoteLogMirror(root: root, run: commands.run)

        do {
            try await mirror.sync(host: "ubuntu-tailscale")
        } catch {
            Harness.expect(false, "sync threw: \(error)")
        }

        let sources = commands.arguments.dropFirst().compactMap { $0.first { $0.hasPrefix("ubuntu-tailscale:") } }
        Harness.expectEqual(
            sources,
            ["ubuntu-tailscale:.claude/projects/", "ubuntu-tailscale:.codex/sessions/"],
            "only directories on the machine are copied"
        )
        let targets = commands.arguments.dropFirst().compactMap(\.last)
        Harness.expectEqual(
            targets,
            [
                root.appendingPathComponent("ubuntu-tailscale/claude/projects").path + "/",
                root.appendingPathComponent("ubuntu-tailscale/codex/sessions").path + "/",
            ],
            "each directory lands in the host's mirror"
        )
        Harness.expect(
            commands.arguments[1].contains("--inplace"),
            "a copy keeps its inode so the recorder resumes it"
        )
        let permissions = (try? FileManager.default.attributesOfItem(atPath: root.path))?[.posixPermissions] as? Int
        Harness.expectEqual(permissions, 0o700, "only this user can read mirrored transcripts")
    }

    private static func unreachableMachineCopiesNothing() async {
        let fixture = RecorderFixture(name: "remote-unreachable")
        defer { fixture.remove() }
        let commands = CommandLog(replies: [
            CommandOutput(status: 255, stderr: "banner\nssh: connect to host: Operation timed out\n"),
        ])
        let mirror = RemoteLogMirror(root: fixture.root, run: commands.run)

        await Self.expectFailure(
            of: mirror,
            equals: .failed("ssh: connect to host: Operation timed out"),
            "ssh's last line says why"
        )
        Harness.expectEqual(commands.arguments.count, 1, "no copy starts without a connection")
    }

    private static func machineWithoutLogsIsReported() async {
        let fixture = RecorderFixture(name: "remote-empty")
        defer { fixture.remove() }
        let commands = CommandLog(replies: [CommandOutput(status: 2, stderr: "ls: no such file")])
        let mirror = RemoteLogMirror(root: fixture.root, run: commands.run)

        await Self.expectFailure(of: mirror, equals: .noLogs, "a machine with no logs is not a success")
    }

    private static func failedCopyReportsItsLastLine() async {
        let fixture = RecorderFixture(name: "remote-copy-failure")
        defer { fixture.remove() }
        let commands = CommandLog(replies: [
            CommandOutput(status: 0, stdout: ".codex/sessions\n"),
            CommandOutput(status: 127, stderr: "rsync: command not found\n"),
        ])
        let mirror = RemoteLogMirror(root: fixture.root, run: commands.run)

        await Self.expectFailure(of: mirror, equals: .failed("rsync: command not found"), "rsync's reason surfaces")
    }

    private static func expectFailure(
        of mirror: RemoteLogMirror,
        equals expected: RemoteSyncError,
        _ message: String
    ) async {
        do {
            try await mirror.sync(host: "ubuntu-tailscale")
            Harness.expect(false, message)
        } catch {
            Harness.expectEqual(error as? RemoteSyncError, expected, message)
        }
    }

    /// A session copied by hand, then mirrored as well, must not count twice in either source.
    private static func sessionsOnBothMachinesCountOnce() {
        let fixture = RecorderFixture(name: "remote-dedupe")
        defer { fixture.remove() }
        let claude = ClaudeLine.assistant(id: "shared", model: "claude-tier", input: 1_000, output: 10)
        let codex = [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ]
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [claude])
        fixture.writeCodexRollout(Self.rollout, lines: codex)
        fixture.record(.claude)
        fixture.record(.codex)

        fixture.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [
            claude,
            ClaudeLine.assistant(id: "remote", model: "claude-tier", input: 2_000, output: 20),
        ])
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: codex)
        fixture.recordMirrored(.claude)
        fixture.recordMirrored(.codex)

        Harness.expectEqual(
            fixture.recorded(.claude)[RecordedTier(model: "claude-tier", longContext: false, isFast: false)],
            TokenTotals(input: 3_000, output: 30),
            "a message on both machines counts once and a new one adds"
        )
        Harness.expectEqual(
            fixture.recorded(.codex)[RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)],
            TokenTotals(input: 100, output: 10),
            "a rollout on both machines counts once"
        )
    }

    private static func mirroredLogsResumeWhereTheyStopped() {
        let fixture = RecorderFixture(name: "remote-resume")
        defer { fixture.remove() }
        let path = "host/codex/archived_sessions/\(Self.rollout)"
        fixture.writeMirrored(path, lines: [
            CodexLine.turnContext(model: "gpt-5.6-sol"),
            CodexLine.tokenCount(input: 100, output: 10, total: 110),
        ])
        fixture.recordMirrored(.codex)
        fixture.appendMirrored(path, lines: [CodexLine.tokenCount(input: 200, output: 20, total: 330)])
        fixture.recordMirrored(.codex)

        Harness.expectEqual(
            fixture.recorded(.codex)[RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)],
            TokenTotals(input: 300, output: 30),
            "an appended mirror adds only its new turns"
        )
    }

    /// A sync can succeed and bring nothing new. The row must tell that apart from a host whose
    /// usage all arrived through it.
    private static func hostUsageSeparatesHeldFromNew() {
        let fixture = RecorderFixture(name: "remote-usage")
        defer { fixture.remove() }
        let shared = ClaudeLine.assistant(id: "shared", model: "claude-tier", input: 1_000, output: 10)
        fixture.writeClaudeTranscript("app/session.jsonl", lines: [shared])
        fixture.writeCodexRollout(Self.rollout, lines: Self.codexLines)
        fixture.record(.claude)
        fixture.record(.codex)

        let streamed = ClaudeLine.assistant(id: "remote", model: "claude-tier", input: 2_000, output: 20)
        fixture.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [shared, streamed, streamed])
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: Self.codexLines)
        fixture.writeMirrored("host/codex/sessions/\(Self.otherRollout)", lines: Self.codexLines)
        fixture.writeMirrored("host/codex/archived_sessions/\(Self.otherRollout)", lines: Self.codexLines)
        fixture.recordMirrored(.claude)
        fixture.recordMirrored(.codex)

        let usage = fixture.remoteUsage("host")
        Harness.expectEqual(usage?.files, 4, "every mirrored log is a file")
        Harness.expectEqual(usage?.records, 4, "shared usage is held, and a session counts once")
        Harness.expectEqual(usage?.newRecords, 2, "only usage no other log recorded first is new")
        Harness.expect((usage?.bytes ?? 0) > 0, "the copied logs have a size")
        Harness.expectEqual(
            fixture.remoteUsage("unsynced"),
            RemoteHostUsage(files: 0, bytes: 0, records: 0, newRecords: 0),
            "a host with no mirror holds nothing"
        )
    }

    private static func logsWithoutUsageHoldNoRecords() {
        let fixture = RecorderFixture(name: "remote-no-usage")
        defer { fixture.remove() }
        fixture.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [#"{"type":"user"}"#])
        fixture.recordMirrored(.claude)

        let usage = fixture.remoteUsage("host")
        Harness.expectEqual(usage?.files, 1, "the log was copied")
        Harness.expectEqual(usage?.records, 0, "a log with no usage holds no records")
    }

    /// Transcripts scanned before hosts' messages were tracked sit past their cursors.
    private static func scannedMirrorsAreCountedAfterAnUpgrade() {
        let fixture = RecorderFixture(name: "remote-upgrade")
        defer { fixture.remove() }
        fixture.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "remote", model: "claude-tier", input: 2_000, output: 20),
        ])
        fixture.recordMirrored(.claude)
        let tier = RecordedTier(model: "claude-tier", longContext: false, isFast: false)
        let before = fixture.recorded(.claude)[tier]

        do {
            try TestDatabase(fixture.databaseURL).exec("DROP TABLE mirrored_message")
            let upgraded = try UsageRecorder(databaseURL: fixture.databaseURL)
            upgraded.record(.claude, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
        } catch {
            Harness.expect(false, "upgrading threw: \(error)")
        }

        Harness.expectEqual(fixture.remoteUsage("host")?.records, 1, "an upgrade rereads scanned mirrors")
        Harness.expectEqual(fixture.recorded(.claude)[tier], before, "rereading a mirror changes no usage")
    }

    private static func restoredBackupKeepsWhatHostsHold() {
        let original = RecorderFixture(name: "remote-backup-original")
        let restored = RecorderFixture(name: "remote-backup-restored")
        defer {
            original.remove()
            restored.remove()
        }
        original.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [
            ClaudeLine.assistant(id: "remote", model: "claude-tier", input: 2_000, output: 20),
        ])
        original.recordMirrored(.claude)
        restored.writeMirrored("host/claude/projects/-home-dev-app/session.jsonl", lines: [])

        do {
            let backup = restored.root.appendingPathComponent("backup.sqlite")
            try original.recorder?.writeSnapshot(to: backup)
            _ = try restored.recorder?.merge(
                backup: backup,
                undoCopy: restored.root.appendingPathComponent("undo.sqlite")
            )
        } catch {
            Harness.expect(false, "restoring threw: \(error)")
        }

        Harness.expectEqual(restored.remoteUsage("host")?.records, 1, "a restored backup keeps what a host held")
    }
}

/// Answers commands from a script and remembers what was asked.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CommandOutput]
    private var received: [[String]] = []

    init(replies: [CommandOutput]) {
        self.replies = replies
    }

    var arguments: [[String]] {
        self.lock.withLock { self.received }
    }

    var run: CommandRunner {
        { [self] _, arguments, _ in
            self.lock.withLock {
                self.received.append(arguments)
                return self.replies.isEmpty ? CommandOutput(status: 0) : self.replies.removeFirst()
            }
        }
    }
}

private extension RecorderFixture {
    var remoteLogs: URL { self.root.appendingPathComponent("remote-logs") }

    func remoteUsage(_ host: String) -> RemoteHostUsage? {
        let usage = try? CostUsageReader.remoteUsage(
            hosts: [host],
            remoteLogs: self.remoteLogs,
            databaseURL: self.databaseURL
        )
        return usage?[host]
    }

    func recordMirrored(_ provider: Provider) {
        self.recorder?.record(provider, rateCard: RateCard(), env: self.env, remoteLogs: self.remoteLogs)
    }

    func writeMirrored(_ relativePath: String, lines: [String]) {
        let file = self.remoteLogs.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func appendMirrored(_ relativePath: String, lines: [String]) {
        guard let handle = try? FileHandle(forWritingTo: self.remoteLogs.appendingPathComponent(relativePath)) else {
            Harness.expect(false, "could not append to \(relativePath)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
