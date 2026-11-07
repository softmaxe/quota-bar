import Foundation
import Darwin

/// What a finished command left behind.
package struct CommandOutput: Sendable, Equatable {
    package var status: Int32
    package var stdout: String
    package var stderr: String

    package init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a command to its end, or stops it at the timeout.
package typealias CommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> CommandOutput

/// Why a machine's logs could not be mirrored. Its description is what Settings shows.
public enum RemoteSyncError: LocalizedError, Equatable {
    case invalidHost
    /// ssh or rsync failed. Carries the last line they printed.
    case failed(String)
    /// The machine answered and holds no Claude Code or Codex logs.
    case noLogs

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "Not a valid SSH host name"
        case let .failed(reason): reason
        case .noLogs: "No Claude Code or Codex logs found"
        }
    }
}

/// A host's recorded contribution and remaining local cache, for Settings.
public struct RemoteHostUsage: Sendable, Equatable {
    public let files: Int
    public let bytes: Int64
    /// Usage records the mirrored logs hold, whichever log recorded them first.
    public let records: Int
    /// The records no other log recorded first.
    public let newRecords: Int

    public init(files: Int, bytes: Int64, records: Int, newRecords: Int) {
        self.files = files
        self.bytes = bytes
        self.records = records
        self.newRecords = newRecords
    }
}

/// Copies the Claude Code and Codex logs of SSH hosts into a local directory, so the Usage
/// recorder reads them the way it reads this Mac's own. rsync's `--inplace` keeps each file's
/// inode, so the recorder resumes a grown log instead of rereading it. The recorder can evict
/// acknowledged versions; each sync verifies their remote bytes before excluding them.
public struct RemoteLogMirror: Sendable {
    /// The mirror's directory beside the database.
    static let directoryName = "remote-logs"

    /// A log directory, relative to the remote home directory and to the host's mirror.
    private struct LogRoot {
        let remote: String
        let mirror: String
    }

    private static let claudeRoots = [
        LogRoot(remote: ".claude/projects", mirror: "claude/projects"),
        LogRoot(remote: ".config/claude/projects", mirror: "config-claude/projects"),
    ]
    private static let codexRoots = [
        LogRoot(remote: ".codex/sessions", mirror: "codex/sessions"),
        LogRoot(remote: ".codex/archived_sessions", mirror: "codex/archived_sessions"),
    ]

    private static let sshPath = "/usr/bin/ssh"
    private static let rsyncPath = "/usr/bin/rsync"
    /// Password and host-key prompts have nobody to answer them, so they fail instead.
    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
    private static let probeTimeout: TimeInterval = 20
    /// The first copy of a long history can be large. rsync's own `--timeout` catches a stall.
    private static let copyTimeout: TimeInterval = 15 * 60
    /// ssh's own exit status. Any other failure of the probe came from `ls` on the machine.
    private static let sshFailureStatus: Int32 = 255

    private let root: URL
    private let run: CommandRunner

    public init(root: URL) {
        self.init(root: root, run: Self.runCommand)
    }

    package init(root: URL, run: @escaping CommandRunner) {
        self.root = root
        self.run = run
    }

    /// Host names reach ssh and rsync as arguments, so nothing here can read as an option.
    public static func isValidHost(_ host: String) -> Bool {
        guard let first = host.unicodeScalars.first, first.isASCIIAlphanumeric else { return false }
        return host.unicodeScalars.allSatisfy {
            $0.isASCIIAlphanumeric || $0 == "." || $0 == "_" || $0 == "-" || $0 == "@"
        }
    }

    /// Brings the host's mirror up to date.
    public func sync(host: String) async throws {
        try await self.sync(host: host, versions: [])
    }

    package func sync(host: String, versions: [RemoteLogVersion]) async throws {
        try Task.checkCancellation()
        guard Self.isValidHost(host) else { throw RemoteSyncError.invalidHost }
        let roots = try await self.presentRoots(on: host)
        try Task.checkCancellation()
        guard !roots.isEmpty else { throw RemoteSyncError.noLogs }

        let verified = try await self.verifiedPaths(host: host, versions: versions.filter(\.evictionPending))
        let hostDirectory = self.root.appendingPathComponent(host, isDirectory: true)
        // Transcripts hold prompts and responses, so only this user may enter the mirror.
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for root in roots {
            try Task.checkCancellation()
            let target = hostDirectory.appendingPathComponent(root.mirror, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let excludes = verified.compactMap { path -> String? in
                guard let relative = Self.safeRelativePath(path, host: host),
                      relative.hasPrefix(root.mirror + "/") else { return nil }
                return "--exclude=/" + String(relative.dropFirst(root.mirror.count + 1))
            }
            try await self.copy(root, from: host, to: target, excludes: excludes)
        }
    }

    package func verifiedPaths(host: String, versions: [RemoteLogVersion]) async throws -> Set<String> {
        guard Self.isValidHost(host) else { throw RemoteSyncError.invalidHost }
        let candidates: [(version: RemoteLogVersion, remote: String)] = versions.compactMap { version in
            guard let relative = Self.safeRelativePath(version.path, host: host),
                  let root = (Self.claudeRoots + Self.codexRoots).first(where: { relative.hasPrefix($0.mirror + "/") })
            else { return nil }
            return (version, root.remote + "/" + String(relative.dropFirst(root.mirror.count + 1)))
        }
        var verified: Set<String> = []
        // Bound command length and reuse each SSH connection for several file checks.
        for start in stride(from: 0, to: candidates.count, by: 32) {
            try Task.checkCancellation()
            let batch = Array(candidates[start..<min(start + 32, candidates.count)])
            let script = batch.enumerated().map { index, candidate in
                "p='\(candidate.remote)'; if n=$(wc -c < \"$p\") && "
                    + "h=$(sha256sum < \"$p\" 2>/dev/null || shasum -a 256 < \"$p\" 2>/dev/null); "
                    + "then set -- $h; printf '%s %s %s\\n' '\(index)' \"$n\" \"$1\"; fi"
            }.joined(separator: "; ") + "; exit 0"
            let command = "sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            do {
                let result = try await self.run(Self.sshPath, Self.sshOptions + [host, command], Self.probeTimeout)
                try Task.checkCancellation()
                guard result.status == 0 else { continue }
                for line in result.stdout.split(whereSeparator: \.isNewline) {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    guard fields.count == 3, let index = Int(fields[0]), batch.indices.contains(index) else { continue }
                    let version = batch[index].version
                    if Int64(fields[1]) == version.size, fields[2] == version.digest {
                        verified.insert(version.path)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A failed probe must download normally. */ }
        }
        return verified
    }

    /// Which log directories the machine has. rsync fails on a missing source, and `ls` lists the
    /// ones present whatever the remote login shell is.
    private func presentRoots(on host: String) async throws -> [LogRoot] {
        let roots = Self.claudeRoots + Self.codexRoots
        try Task.checkCancellation()
        let output = try await self.run(
            Self.sshPath,
            Self.sshOptions + [host, "ls", "-d"] + roots.map(\.remote),
            Self.probeTimeout
        )
        try Task.checkCancellation()
        if output.status == Self.sshFailureStatus { throw Self.failure(output) }
        let present = Set(output.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return roots.filter { present.contains($0.remote) }
    }

    private func copy(_ root: LogRoot, from host: String, to target: URL, excludes: [String]) async throws {
        try Task.checkCancellation()
        let output = try await self.run(
            Self.rsyncPath,
            [
                "-rtz",
                "--inplace",
                "--checksum",
                "--prune-empty-dirs",
                "--timeout=60",
            ] + excludes + [
                "--include=*/",
                "--include=*.jsonl",
                "--exclude=*",
                "-e", ([Self.sshPath] + Self.sshOptions).joined(separator: " "),
                "\(host):\(root.remote)/",
                target.path + "/",
            ],
            Self.copyTimeout
        )
        try Task.checkCancellation()
        guard output.status == 0 else { throw Self.failure(output) }
    }

    private static func failure(_ output: CommandOutput) -> RemoteSyncError {
        let line = output.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
        return .failed(line ?? "Exited with status \(output.status)")
    }

    /// The log directories of every mirrored host, kept even once a host leaves Settings, since
    /// what was recorded from them stays recorded.
    static func claudeRoots(under root: URL) -> [URL] {
        self.mirrored(self.claudeRoots, under: root)
    }

    static func codexRoots(under root: URL) -> [URL] {
        self.mirrored(self.codexRoots, under: root)
    }

    private static func mirrored(_ roots: [LogRoot], under root: URL) -> [URL] {
        let hosts = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return hosts.flatMap { host in
            roots.map { host.appendingPathComponent($0.mirror, isDirectory: true) }
        }
    }

    /// The host whose mirror holds the log at `path`. Read from the path alone, because a listing
    /// can spell a symlinked root differently from the URL it was asked about.
    static func host(ofLog path: String) -> String? {
        guard let marker = path.range(of: "/\(self.directoryName)/") else { return nil }
        return path[marker.upperBound...].split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// Wildcards, shell syntax, control characters and ambiguous components are never evicted.
    package static func safeRelativePath(_ path: String, host: String) -> String? {
        guard let marker = path.range(of: self.pathMarker(of: host)) else { return nil }
        let relative = String(path[marker.upperBound...])
        guard relative.unicodeScalars.allSatisfy({
            $0.isASCIIAlphanumeric || "-._/".unicodeScalars.contains($0)
        }), relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }), (self.claudeRoots + self.codexRoots).contains(where: { relative.hasPrefix($0.mirror + "/") })
        else { return nil }
        return relative
    }

    /// What every path under a host's mirror contains.
    static func pathMarker(of host: String) -> String {
        "/\(self.directoryName)/\(host)/"
    }

    /// The logs mirrored from `host`. Empty before its first sync.
    static func logs(of host: String, under root: URL) -> [URL] {
        LogFileScanner.jsonlFiles(under: [root.appendingPathComponent(host, isDirectory: true)])
    }

    /// Output goes to files rather than pipes: an ssh `ControlPersist` master inherits them and
    /// outlives the command, so reading a pipe to its end could wait for hours.
    package static let runCommand: CommandRunner = { executable, arguments, timeout in
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        defer {
            try? (process.standardOutput as? FileHandle)?.close()
            try? (process.standardError as? FileHandle)?.close()
        }
        let execution = CommandExecution(process: process)
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
        try Task.checkCancellation()

        return CommandOutput(
            status: status,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }
}

/// Serializes cancellation with launch and keeps the timeout alive only while the child runs.
private final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var timer: DispatchSourceTimer?

    init(process: Process) { self.process = process }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<Int32, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.cancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.process.terminationHandler = { [self] process in
            self.lock.withLock {
                self.timer?.cancel()
                self.timer = nil
                process.terminationHandler = nil
            }
            continuation.resume(returning: process.terminationStatus)
        }
        do {
            try self.process.run()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.cancel() }
            self.timer = timer
            timer.resume()
        } catch {
            self.process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        self.lock.withLock {
            self.cancelled = true
            // Wait for the termination handler before allowing another copy of this host.
            // SIGKILL also bounds cancellation when the command ignores SIGTERM.
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            self.timer?.cancel()
            self.timer = nil
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        self.isASCII && (self.properties.isAlphabetic || self.properties.numericType != nil)
    }
}

/// The concrete hosts an OpenSSH config names, in its order, for picking one instead of typing
/// it. Patterns such as `*` and `!host` match hosts rather than name one, so they are left out.
public enum SSHConfigHosts {
    public static func parse(_ config: String) -> [String] {
        var hosts: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.first?.lowercased() == "host" else { continue }
            for host in fields.dropFirst() where RemoteLogMirror.isValidHost(host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    /// The hosts of `~/.ssh/config`, or none when it cannot be read.
    public static func userHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return (try? String(contentsOf: url, encoding: .utf8)).map(Self.parse) ?? []
    }
}
