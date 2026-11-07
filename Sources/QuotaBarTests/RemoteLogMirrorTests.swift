import QuotaBarCore
@testable import QuotaBarApp
import Foundation
import Darwin

/// Mirroring other machines' logs: what reaches ssh and rsync, how a failure surfaces, and that
/// mirrored logs count once alongside this Mac's own.
enum RemoteLogMirrorTests {
    static func run() async {
        await Self.evictedLogsResumeSafely()
        Self.incompleteLogsStayLocal()
        Self.fullPrefixAndAnonymousClaudeResume()
        Self.manifestFailureRollsBackTokens()
        Self.legacyLogsGainCleanupEvidenceWithoutReplay()
        Self.localSessionCopyCanContinueAfterEviction()
        await Self.batchChecksUseRealShellWithoutNetwork()
        await Self.serviceCancellationKeepsHostBusy()
        Self.hostNamesCannotReadAsOptions()
        Self.configHostsLeaveOutPatterns()
        await Self.manualRefreshKeepsHostsManualUntilChanged()
        await Self.syncCopiesOnlyTheDirectoriesTheMachineHas()
        await Self.unreachableMachineCopiesNothing()
        await Self.machineWithoutLogsIsReported()
        await Self.failedCopyReportsItsLastLine()
        await Self.cancellationStopsFurtherCommands()
        await Self.removeAndReaddWaitsForCancellation()
        await Self.nativeCommandCancellationCleansUp()
        Self.sessionsOnBothMachinesCountOnce()
        Self.mirroredLogsResumeWhereTheyStopped()
        Self.hostUsageSeparatesHeldFromNew()
        Self.logsWithoutUsageHoldNoRecords()
        Self.scannedMirrorsAreCountedAfterAnUpgrade()
        Self.restoredBackupKeepsWhatHostsHold()
    }

    private static func evictedLogsResumeSafely() async {
        let fixture = RecorderFixture(name: "eviction")
        defer { fixture.remove() }
        let path = "host/codex/sessions/\(Self.rollout)"
        let url = fixture.remoteLogs.appendingPathComponent(path)
        fixture.writeMirrored(path, lines: Self.codexLines)
        fixture.recordMirrored(.codex)
        do {
            guard let recorder = fixture.recorder else { return }
            try recorder.evictVerifiedMirror(host: "host")
            Harness.expect(FileManager.default.fileExists(atPath: url.path), "recent logs stay local")
            try recorder.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            Harness.expect(!FileManager.default.fileExists(atPath: url.path), "stable recorded logs are evicted")
            Harness.expectEqual(fixture.remoteUsage("host")?.records, 1, "eviction preserves host record counts")
            let restarted = try UsageRecorder(databaseURL: fixture.databaseURL)
            let versions = try restarted.remoteVersions(host: "host")
            Harness.expectEqual(versions.count, 1, "manifest survives restart")
            guard let version = versions.first else { return }
            for reply in [CommandOutput(status: 0, stdout: "0 \(version.size) \(version.digest)"),
                          CommandOutput(status: 127), CommandOutput(status: 0, stdout: "1 changed")] {
                let commands = CommandLog(replies: [
                    CommandOutput(status: 0, stdout: ".codex/sessions\n"), reply, CommandOutput(status: 0),
                ])
                try await RemoteLogMirror(root: fixture.remoteLogs, run: commands.run).sync(host: "host", versions: versions)
                let excluded = commands.arguments.last?.contains("--exclude=/" + Self.rollout) == true
                Harness.expectEqual(excluded, reply.stdout.contains(version.digest), "only freshly verified versions are excluded")
            }
            fixture.writeMirrored(path, lines: Self.codexLines)
            restarted.record(.codex, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
            let tier = RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)
            Harness.expectEqual(fixture.recorded(.codex)[tier], TokenTotals(input: 100, output: 10), "redownload does not replay")
            fixture.appendMirrored(path, lines: [CodexLine.tokenCount(input: 200, output: 20, total: 330)])
            restarted.record(.codex, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
            Harness.expectEqual(fixture.recorded(.codex)[tier], TokenTotals(input: 300, output: 30), "redownload resumes parser state")
            fixture.writeMirrored(path, lines: [CodexLine.turnContext(model: "changed")])
            restarted.record(.codex, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
            Harness.expectEqual(restarted.scanStatus(of: .codex), .error("sessions"), "rewrites report failure")
            Harness.expectEqual(fixture.recorded(.codex)[tier], TokenTotals(input: 300, output: 30), "rewrites preserve historical tokens")
        } catch { Harness.expect(false, "eviction test failed: \(error)") }
    }

    private static func incompleteLogsStayLocal() {
        let fixture = RecorderFixture(name: "eviction-incomplete")
        defer { fixture.remove() }
        let paths = ["host/claude/projects/app/partial.jsonl", "host/claude/projects/app/invalid.jsonl",
                     "host/claude/projects/app/unsafe[1].jsonl"]
        let line = ClaudeLine.assistant(id: "one", model: "claude-tier", input: 100, output: 10)
        for path in paths { fixture.writeMirrored(path, lines: [line]) }
        do {
            let partial = fixture.remoteLogs.appendingPathComponent(paths[0])
            try (line + "\n{").write(to: partial, atomically: true, encoding: .utf8)
            fixture.appendMirrored(paths[1], lines: ["invalid json"])
            fixture.recordMirrored(.claude)
            try fixture.recorder?.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            for path in paths {
                Harness.expect(FileManager.default.fileExists(atPath: fixture.remoteLogs.appendingPathComponent(path).path),
                               "partial, malformed and unrepresentable logs are retained")
            }
            fixture.appendMirrored(paths[0], lines: ["}"])
            fixture.recordMirrored(.claude)
            try fixture.recorder?.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            Harness.expect(!FileManager.default.fileExists(atPath: partial.path), "a completed trailing line becomes eligible")
            Harness.expect(FileManager.default.fileExists(atPath: fixture.remoteLogs.appendingPathComponent(paths[1]).path),
                           "malformed history stays ineligible after later scans")
            fixture.recorder?.busyRemoteHosts.insert("host")
            fixture.writeMirrored("host/claude/projects/app/busy.jsonl", lines: [
                ClaudeLine.assistant(id: "busy", model: "claude-tier", input: 900, output: 90),
            ])
            fixture.recordMirrored(.claude)
            Harness.expectEqual(fixture.remoteUsage("host")?.records, 1, "scans skip a host while rsync is writing")
        } catch { Harness.expect(false, "incomplete test failed: \(error)") }
    }

    private static func legacyLogsGainCleanupEvidenceWithoutReplay() {
        let fixture = RecorderFixture(name: "eviction-legacy")
        defer { fixture.remove() }
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: Self.codexLines)
        fixture.writeMirrored("host/claude/projects/app/anonymous.jsonl", lines: [
            ClaudeLine.assistant(id: "", requestId: "", model: "claude-tier", input: 100, output: 10),
        ])
        fixture.recordMirrored(.codex)
        fixture.recordMirrored(.claude)
        let claudeBefore = fixture.recorded(.claude)
        let codexBefore = fixture.recorded(.codex)
        do {
            // Simulate an existing installation whose cursors predate cleanup evidence.
            try TestDatabase(fixture.databaseURL).exec("DELETE FROM remote_manifest")
            fixture.recordMirrored(.codex)
            fixture.recordMirrored(.claude)
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 2,
                                "unchanged legacy logs receive evidence without waiting for an append")
            Harness.expectEqual(fixture.recorded(.claude), claudeBefore, "certification never replays anonymous messages")
            Harness.expectEqual(fixture.recorded(.codex), codexBefore, "certification preserves existing Codex totals")
            let backup = fixture.root.appendingPathComponent("legacy-backup.sqlite")
            try fixture.recorder?.writeSnapshot(to: backup)
            _ = try fixture.recorder?.merge(backup: backup, undoCopy: fixture.root.appendingPathComponent("undo.sqlite"))
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 0,
                                "import invalidates existing eviction proofs as well as imported proofs")
            fixture.recordMirrored(.codex)
            fixture.recordMirrored(.claude)
            Harness.expectEqual(fixture.recorded(.claude), claudeBefore, "imported remote cursors resume without replay")
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 2,
                                "merged cursors can be certified again")
            try fixture.recorder?.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            Harness.expectEqual(fixture.remoteUsage("host")?.files, 0, "legacy cached files can be removed")
            Harness.expectEqual(fixture.remoteUsage("host")?.bytes, 0, "cache size excludes removed files")
            Harness.expectEqual(fixture.remoteUsage("host")?.records, 2, "both hosts' historical records survive an empty cache")
        } catch { Harness.expect(false, "legacy certification failed: \(error)") }
    }

    private static func localSessionCopyCanContinueAfterEviction() {
        let fixture = RecorderFixture(name: "eviction-local-copy")
        defer { fixture.remove() }
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: Self.codexLines)
        fixture.recordMirrored(.codex)
        do {
            try fixture.recorder?.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            fixture.writeCodexRollout(Self.rollout, lines: Self.codexLines + [
                CodexLine.tokenCount(input: 200, output: 20, total: 330),
            ])
            fixture.recordMirrored(.codex)
            fixture.recordMirrored(.codex)
            let tier = RecordedTier(model: "gpt-5.6-sol", longContext: false, isFast: false)
            Harness.expectEqual(fixture.recorded(.codex)[tier], TokenTotals(input: 300, output: 30),
                                "another session copy resumes exactly once after eviction")
            Harness.expectEqual(fixture.recorder?.scanStatus(of: .codex), .idle,
                                "the updated manifest follows the canonical session cursor")
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 1,
                                "continued canonical session retains consistent evidence")
        } catch { Harness.expect(false, "local-copy continuation failed: \(error)") }
    }

    private static func batchChecksUseRealShellWithoutNetwork() async {
        let fixture = RecorderFixture(name: "eviction-checksum-shell")
        defer { fixture.remove() }
        do {
            var versions: [RemoteLogVersion] = []
            for index in 0..<2 {
                let suffix = "app/session-\(index).jsonl"
                let remote = fixture.root.appendingPathComponent(".claude/projects/" + suffix)
                try FileManager.default.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = Data("{\"type\":\"user\",\"text\":\"example\"}\n".utf8)
                try bytes.write(to: remote)
                versions.append(RemoteLogVersion(
                    path: fixture.remoteLogs.appendingPathComponent("host/claude/projects/" + suffix).path,
                    size: Int64(bytes.count), digest: try LogFileScanner.prefixDigest(of: remote, byteCount: Int64(bytes.count)),
                    state: nil, observedAt: Date(), validJSON: true, complete: true, evictionPending: true
                ))
            }
            let changed = fixture.root.appendingPathComponent(".claude/projects/app/session-1.jsonl")
            try Data("changed contents\n".utf8).write(to: changed)
            let remoteHome = fixture.root.path
            let mirror = RemoteLogMirror(root: fixture.remoteLogs, run: { _, arguments, timeout in
                try await RemoteLogMirror.runCommand(
                    "/bin/sh", ["-c", "cd \"$1\" && eval \"$2\"", "test", remoteHome, arguments.last ?? ""], timeout
                )
            })
            let verified = try await mirror.verifiedPaths(host: "host", versions: versions)
            Harness.expectEqual(verified, Set([versions[0].path]), "real shell hashes each batch file and rejects changed contents")
            let commands = CommandLog(replies: [CommandOutput(status: 0, stdout: "0 \(versions[0].size) \(versions[0].digest)\n")])
            _ = try await RemoteLogMirror(root: fixture.remoteLogs, run: commands.run).verifiedPaths(host: "host", versions: versions)
            Harness.expectEqual(commands.arguments.count, 1, "multiple file checks share an SSH request")
        } catch { Harness.expect(false, "checksum shell test failed: \(error)") }
    }

    private static func fullPrefixAndAnonymousClaudeResume() {
        let fixture = RecorderFixture(name: "eviction-full-prefix")
        defer { fixture.remove() }
        let path = "host/claude/projects/app/session.jsonl"
        let padding = "{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 70000) + "\"}"
        let line = ClaudeLine.assistant(id: "", requestId: "", model: "claude-tier", input: 100, output: 10)
        fixture.writeMirrored(path, lines: [padding, line])
        fixture.recordMirrored(.claude)
        let tier = RecordedTier(model: "claude-tier", longContext: false, isFast: false)
        let original = fixture.recorded(.claude)[tier]
        do {
            try fixture.recorder?.evictVerifiedMirror(host: "host", now: Date().addingTimeInterval(86401))
            let restarted = try UsageRecorder(databaseURL: fixture.databaseURL)
            fixture.writeMirrored(path, lines: [padding, line])
            restarted.record(.claude, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
            Harness.expectEqual(fixture.recorded(.claude)[tier], original, "anonymous Claude rows are not replayed after eviction")
            fixture.writeMirrored(path, lines: [padding, line.replacingOccurrences(of: "100", with: "200")])
            restarted.record(.claude, rateCard: RateCard(), env: fixture.env, remoteLogs: fixture.remoteLogs)
            Harness.expectEqual(restarted.scanStatus(of: .claude), .error("sessions"), "rewrite beyond 64KB is detected")
            Harness.expectEqual(fixture.recorded(.claude)[tier], original, "late rewrites preserve history")
            let restored = RecorderFixture(name: "eviction-import")
            defer { restored.remove() }
            let backup = fixture.root.appendingPathComponent("backup.sqlite")
            try restarted.writeSnapshot(to: backup)
            _ = try restored.recorder?.merge(backup: backup, undoCopy: restored.root.appendingPathComponent("undo.sqlite"))
            Harness.expectEqual(try restored.recorder?.remoteVersions(host: "host").count, 0, "imports never inherit exclusion eligibility")
        } catch { Harness.expect(false, "full prefix test failed: \(error)") }
    }

    private static func serviceCancellationKeepsHostBusy() async {
        let fixture = RecorderFixture(name: "eviction-service-busy")
        defer { fixture.remove() }
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: Self.codexLines)
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: RateCard())
        let commands = SuspendedRemoteCommand(suspended: 2)
        let mirror = RemoteLogMirror(root: fixture.remoteLogs, run: commands.run)
        let task = Task { try await service.syncRemote(host: "host", mirror: mirror) }
        Harness.expect(await Self.eventually { commands.isSuspended }, "service holds host during copy")
        _ = await service.refresh(.codex)
        Harness.expectEqual(fixture.remoteUsage("host")?.records, 0, "background scans cannot see in-flight copies")
        do {
            try await service.syncRemote(host: "host", mirror: mirror)
            Harness.expect(false, "overlapping sync must fail")
        } catch { Harness.expectEqual(commands.count, 2, "overlap starts no commands") }
        task.cancel()
        commands.release()
        do {
            try await task.value
            Harness.expect(false, "service cancellation must propagate")
        } catch { Harness.expect(error is CancellationError, "service preserves cancellation") }
        _ = await service.refresh(.codex)
        Harness.expectEqual(fixture.remoteUsage("host")?.records, 1, "cancellation releases scan guard")
    }

    private static func manifestFailureRollsBackTokens() {
        let fixture = RecorderFixture(name: "eviction-transaction")
        defer { fixture.remove() }
        fixture.writeMirrored("host/codex/sessions/\(Self.rollout)", lines: Self.codexLines)
        do {
            try TestDatabase(fixture.databaseURL).exec("""
                CREATE TRIGGER reject_manifest BEFORE INSERT ON remote_manifest
                BEGIN SELECT RAISE(FAIL, 'injected manifest failure'); END
                """)
            fixture.recordMirrored(.codex)
            Harness.expectEqual(fixture.remoteUsage("host")?.records, 0, "manifest failure rolls back tokens")
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 0, "failed transaction has no cleanup evidence")
            Harness.expectEqual(fixture.recorder?.scanStatus(of: .codex), .error("sessions"), "failed transaction reports scan error")
            try TestDatabase(fixture.databaseURL).exec("DROP TRIGGER reject_manifest")
            fixture.recordMirrored(.codex)
            Harness.expectEqual(fixture.remoteUsage("host")?.records, 1, "retry resumes from uncommitted cursor without loss")
            let duplicate = "host/codex/archived_sessions/\(Self.rollout)"
            fixture.writeMirrored(duplicate, lines: Self.codexLines)
            fixture.recordMirrored(.codex)
            Harness.expectEqual(try fixture.recorder?.remoteVersions(host: "host").count, 1, "deduplicated copies gain no eviction eligibility")
        } catch { Harness.expect(false, "transaction test failed: \(error)") }
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

    private static func cancellationStopsFurtherCommands() async {
        for suspended in [1, 2] {
            let fixture = RecorderFixture(name: "remote-cancel-\(suspended)")
            defer { fixture.remove() }
            let commands = SuspendedRemoteCommand(suspended: suspended)
            let root = fixture.root.appendingPathComponent("mirror")
            let mirror = RemoteLogMirror(root: root, run: commands.run)
            let task = Task { try await mirror.sync(host: "host") }
            let reached = await Self.eventually { commands.isSuspended }
            Harness.expect(reached, "the dummy command reaches its suspension")
            task.cancel()
            commands.release()
            do {
                try await task.value
                Harness.expect(false, "cancelled mirror must throw")
            } catch {
                Harness.expect(error is CancellationError, "cancellation is preserved")
            }
            Harness.expectEqual(commands.count, suspended, "cancellation starts no further commands")
            if suspended == 1 {
                Harness.expect(!FileManager.default.fileExists(atPath: root.path), "cancelled probe creates no mirror")
            } else {
                Harness.expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("host/codex/sessions").path), "cancelled copy creates no later root")
            }
        }
    }

    @MainActor
    private static func removeAndReaddWaitsForCancellation() async {
        for suspended in [1, 2] {
            let fixture = RecorderFixture(name: "remote-readd-\(suspended)")
            defer { fixture.remove() }
            let settings = SettingsStore(defaults: EphemeralDefaults.make("RemoteReadd-\(suspended)"))
            let commands = SuspendedRemoteCommand(suspended: suspended)
            var successes = 0
            let model = RemoteSyncModel(
                settings: settings,
                mirror: RemoteLogMirror(root: fixture.root, run: commands.run),
                didSync: { successes += 1 }
            )
            let retained = fixture.root.appendingPathComponent("host/retained.jsonl")
            try? FileManager.default.createDirectory(at: retained.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("existing transcript".utf8).write(to: retained)
            model.add("host")
            let reached = await Self.eventually { commands.isSuspended }
            Harness.expect(reached, "model reaches suspended command")
            model.remove("host")
            Harness.expect(FileManager.default.fileExists(atPath: retained.path), "removing a host preserves old mirror data")
            Harness.expectEqual(model.state(of: "host"), .idle, "removed host has no stale state")
            model.add("host")
            for _ in 0..<100 { await Task.yield() }
            Harness.expectEqual(commands.count, suspended, "replacement waits for previous command to finish")
            commands.release()
            let finished = await Self.eventually { !model.isSyncing }
            Harness.expect(finished, "replacement finishes within the test deadline")
            Harness.expectEqual(successes, 1, "only replacement requests a scan")
            Harness.expectEqual(commands.count, suspended + 3, "replacement runs exactly one probe and two copies")
            if case .synced = model.state(of: "host") {} else {
                Harness.expect(false, "replacement owns the final UI state")
            }
            model.stop()
        }
    }

    private static func nativeCommandCancellationCleansUp() async {
        let fixture = RecorderFixture(name: "remote-process-cancel")
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("started")
        let task = Task {
            try await RemoteLogMirror.runCommand(
                "/bin/sh", ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "test", marker.path], 2
            )
        }
        let reached = await Self.eventually { FileManager.default.fileExists(atPath: marker.path) }
        Harness.expect(reached, "local dummy process starts without network access")
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            Harness.expect(false, "cancelled native command must throw")
        } catch {
            Harness.expect(error is CancellationError, "native command reports cancellation")
        }
        Harness.expect(Date().timeIntervalSince(start) < 1, "cancellation does not wait for timeout")
        if let raw = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Harness.expect(kill(pid, 0) == -1, "cancelled child has exited before completion")
        }
    }

    @MainActor
    private static func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
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

/// Deliberately ignores task cancellation to exercise the mirror's post-await checks.
private final class SuspendedRemoteCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let suspended: Int
    private var received = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspended: Int) { self.suspended = suspended }
    var count: Int { self.lock.withLock { self.received } }
    var isSuspended: Bool { self.lock.withLock { self.continuation != nil } }

    func release() {
        let continuation = self.lock.withLock {
            let result = self.continuation
            self.continuation = nil
            return result
        }
        continuation?.resume()
    }

    var run: CommandRunner {
        { [self] executable, _, _ in
            let pause = self.lock.withLock {
                self.received += 1
                return self.received == self.suspended
            }
            if pause {
                await withCheckedContinuation { continuation in
                    self.lock.withLock { self.continuation = continuation }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.release() }
                }
            }
            return CommandOutput(status: 0, stdout: executable == "/usr/bin/ssh" ? ".claude/projects\n.codex/sessions\n" : "")
        }
    }
}

private extension UsageRecorder {
    /// Unit tests supply the same evidence that the service obtains from its SSH probe.
    func evictVerifiedMirror(host: String, now: Date = Date()) throws {
        let paths = Set(try self.remoteVersions(host: host).map(\.path))
        try self.cleanupRemoteLogs(host: host, now: now, verifiedPaths: paths)
    }
}
