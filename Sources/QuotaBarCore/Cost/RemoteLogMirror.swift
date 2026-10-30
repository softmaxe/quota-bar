import Foundation

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

/// Copies the Claude Code and Codex logs of SSH hosts into a local directory, so the Usage
/// recorder reads them the way it reads this Mac's own. rsync's `--inplace` keeps each file's
/// inode, so the recorder resumes a grown log instead of rereading it. Nothing is ever deleted
/// from the mirror: a log the remote tool cleans up remains recorded here.
public struct RemoteLogMirror: Sendable {
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
        guard Self.isValidHost(host) else { throw RemoteSyncError.invalidHost }
        let roots = try await self.presentRoots(on: host)
        guard !roots.isEmpty else { throw RemoteSyncError.noLogs }

        let hostDirectory = self.root.appendingPathComponent(host, isDirectory: true)
        // Transcripts hold prompts and responses, so only this user may enter the mirror.
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for root in roots {
            let target = hostDirectory.appendingPathComponent(root.mirror, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try await self.copy(root, from: host, to: target)
        }
    }

    /// Which log directories the machine has. rsync fails on a missing source, and `ls` lists the
    /// ones present whatever the remote login shell is.
    private func presentRoots(on host: String) async throws -> [LogRoot] {
        let roots = Self.claudeRoots + Self.codexRoots
        let output = try await self.run(
            Self.sshPath,
            Self.sshOptions + [host, "ls", "-d"] + roots.map(\.remote),
            Self.probeTimeout
        )
        if output.status == Self.sshFailureStatus { throw Self.failure(output) }
        let present = Set(output.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return roots.filter { present.contains($0.remote) }
    }

    private func copy(_ root: LogRoot, from host: String, to target: URL) async throws {
        let output = try await self.run(
            Self.rsyncPath,
            [
                "-rtz",
                "--inplace",
                "--prune-empty-dirs",
                "--timeout=60",
                "--include=*/",
                "--include=*.jsonl",
                "--exclude=*",
                "-e", ([Self.sshPath] + Self.sshOptions).joined(separator: " "),
                "\(host):\(root.remote)/",
                target.path + "/",
            ],
            Self.copyTimeout
        )
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

    /// Output goes to files rather than pipes: an ssh `ControlPersist` master inherits them and
    /// outlives the command, so reading a pipe to its end could wait for hours.
    private static let runCommand: CommandRunner = { executable, arguments, timeout in
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

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }

        return CommandOutput(
            status: status,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
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
