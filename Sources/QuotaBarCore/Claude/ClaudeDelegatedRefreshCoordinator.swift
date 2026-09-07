// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift
// Kept: delegated, user-triggered CLI refresh and the ownership boundary around Claude Code's
// credentials. This app supplies its own minimal PTY runner and does not parse CLI output.

import Darwin
import Foundation

/// The only request the delegated runner is allowed to execute.
public struct ClaudeDelegatedRefreshRequest: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    public let command: String
    public let environment: [String: String]
    public let workingDirectoryPath: String
    public let timeout: TimeInterval

    public init(
        executablePath: String,
        arguments: [String],
        command: String,
        environment: [String: String],
        workingDirectoryPath: String,
        timeout: TimeInterval
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.command = command
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.timeout = timeout
    }
}

/// Runs the already-located Claude CLI. Tests inject a fake runner so no real process starts.
public protocol ClaudeDelegatedRefreshRunner: Sendable {
    func run(_ request: ClaudeDelegatedRefreshRequest) async throws
}

/// Finds one executable path for the Claude CLI. There is no second locator in the provider.
public struct ClaudeCLILocator: Sendable {
    private let isExecutable: @Sendable (String) -> Bool

    public init(isExecutable: @escaping @Sendable (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }) {
        self.isExecutable = isExecutable
    }

    public func locate(in environment: [String: String]) -> String? {
        if let override = Self.nonEmpty(environment["CLAUDE_CLI_PATH"]) {
            let expanded = Self.expandedPath(override)
            return self.isExecutable(expanded) ? expanded : nil
        }

        if let path = environment["PATH"] {
            for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = URL(fileURLWithPath: Self.expandedPath(String(directory)), isDirectory: true)
                    .appendingPathComponent("claude")
                    .path
                if self.isExecutable(candidate) {
                    return candidate
                }
            }
        }

        for candidate in Self.commonHomebrewPaths where self.isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    public static let commonHomebrewPaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/home/linuxbrew/.linuxbrew/bin/claude",
    ]

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// Environment filtering for the delegated process. Claude's own profile variables remain.
public enum ClaudeDelegatedRefreshEnvironment {
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        var result = environment
        let anthropicKeys = result.keys.filter { $0.hasPrefix("ANTHROPIC_") }
        for key in anthropicKeys {
            result.removeValue(forKey: key)
        }
        result["DISABLE_AUTOUPDATER"] = "1"
        if result["TERM"] == nil {
            result["TERM"] = "xterm-256color"
        }
        return result
    }
}

public enum ClaudeDelegatedRefreshError: Error, LocalizedError, Sendable, Equatable {
    case automaticNotAllowed
    case cooldown
    case alreadyRunning
    case cliUnavailable
    case timedOut
    case processFailed

    public var errorDescription: String? {
        switch self {
        case .automaticNotAllowed:
            "Automatic Claude credential recovery is disabled."
        case .cooldown:
            "Claude credential recovery is cooling down."
        case .alreadyRunning:
            "Claude credential recovery is already in progress."
        case .cliUnavailable:
            "Claude CLI is unavailable for credential recovery."
        case .timedOut:
            "Claude credential recovery timed out."
        case .processFailed:
            "Claude credential recovery did not complete."
        }
    }
}

/// Starts Claude Code only after an explicit Refresh click, with one short attempt per cooldown.
public actor ClaudeDelegatedRefreshCoordinator {
    public static let shared = ClaudeDelegatedRefreshCoordinator()
    public static let timeout: TimeInterval = 5
    public static let cooldown: TimeInterval = 30
    public static let stableSessionID = "2F6B3A8C-0D2C-4E89-9DA4-2BDBD7C6C3C4"

    private let runner: any ClaudeDelegatedRefreshRunner
    private let locator: ClaudeCLILocator
    private let environment: [String: String]
    private let now: @Sendable () -> TimeInterval
    private var cooldownGate = RefreshCooldownGate(
        minimumInterval: ClaudeDelegatedRefreshCoordinator.cooldown,
        tolerance: 0
    )
    private var isRunning = false

    public init(
        runner: any ClaudeDelegatedRefreshRunner = ClaudePTYRunner(),
        locator: ClaudeCLILocator = ClaudeCLILocator(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.runner = runner
        self.locator = locator
        self.environment = environment
        self.now = now
    }

    public func refresh(
        interaction: ClaudeRefreshInteraction = .userInitiated
    ) async throws {
        guard interaction == .userInitiated else {
            throw ClaudeDelegatedRefreshError.automaticNotAllowed
        }
        guard !self.isRunning else {
            throw ClaudeDelegatedRefreshError.alreadyRunning
        }

        let currentTime = self.now()
        guard self.cooldownGate.remaining(at: currentTime) == 0 else {
            throw ClaudeDelegatedRefreshError.cooldown
        }

        guard let executablePath = self.locator.locate(in: self.environment) else {
            throw ClaudeDelegatedRefreshError.cliUnavailable
        }

        self.cooldownGate.recordRefresh(at: currentTime)
        self.isRunning = true
        defer { self.isRunning = false }

        let request = ClaudeDelegatedRefreshRequest(
            executablePath: executablePath,
            arguments: [
                "--allowed-tools", "",
                "--strict-mcp-config",
                "--session-id", Self.stableSessionID,
            ],
            command: "/status",
            environment: ClaudeDelegatedRefreshEnvironment.sanitized(self.environment),
            workingDirectoryPath: "/",
            timeout: Self.timeout
        )

        do {
            try await self.runner.run(request)
        } catch let error as ClaudePTYRunnerError {
            switch error {
            case .timedOut:
                throw ClaudeDelegatedRefreshError.timedOut
            default:
                throw ClaudeDelegatedRefreshError.processFailed
            }
        } catch {
            throw ClaudeDelegatedRefreshError.processFailed
        }
    }
}

public enum ClaudePTYRunnerError: Error, LocalizedError, Sendable, Equatable {
    case couldNotCreatePTY
    case launchFailed
    case timedOut
    case cancelled
    case processExited(Int32)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreatePTY:
            "Claude credential recovery could not create a PTY."
        case .launchFailed:
            "Claude credential recovery could not launch Claude CLI."
        case .timedOut:
            "Claude credential recovery timed out."
        case .cancelled:
            "Claude credential recovery was cancelled."
        case let .processExited(status):
            "Claude credential recovery exited with status \(status)."
        }
    }
}

/// A hidden PTY process runner. It drains output without interpreting it, then closes every FD.
public struct ClaudePTYRunner: ClaudeDelegatedRefreshRunner {
    public init() {}

    public func run(_ request: ClaudeDelegatedRefreshRequest) async throws {
        try Task.checkCancellation()
        let process = try ClaudePTYProcess(request: request)
        try await process.run()
    }
}

private final class ClaudePTYProcess: @unchecked Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private let process: Process
    private let master: FileHandle
    private let slave: FileHandle
    private let command: String
    private let timeoutNanoseconds: UInt64
    private let lock = NSLock()
    private var completion: ((Result<Void, Error>) -> Void)?
    private var processGroupID: pid_t?
    private var rootIdentity: ProcessIdentity?
    private var capturedDescendants: [ProcessIdentity] = []
    private var didFinish = false
    private var didTimeout = false
    private var didCancel = false
    private var didTerminate = false
    private var didFail: Error?
    private var masterClosed = false
    private var slaveClosed = false

    init(request: ClaudeDelegatedRefreshRequest) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw ClaudePTYRunnerError.couldNotCreatePTY
        }

        self.process = Process()
        self.master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        self.slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        self.command = request.command
        self.timeoutNanoseconds = UInt64(max(0, request.timeout) * 1_000_000_000)
        self.process.executableURL = URL(fileURLWithPath: request.executablePath)
        self.process.arguments = request.arguments
        self.process.environment = request.environment
        self.process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectoryPath)
        self.process.standardInput = self.slave
        self.process.standardOutput = self.slave
        self.process.standardError = self.slave
    }

    func run() async throws {
        let timeoutNanoseconds = self.timeoutNanoseconds
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.timeout()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.start { result in
                    continuation.resume(with: result)
                }
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func start(completion: @escaping (Result<Void, Error>) -> Void) {
        self.lock.lock()
        self.completion = completion
        let cancelled = self.didCancel
        self.lock.unlock()

        if cancelled {
            self.finish(.failure(ClaudePTYRunnerError.cancelled))
            return
        }

        self.master.readabilityHandler = { handle in
            _ = try? handle.read(upToCount: 64 * 1024)
        }
        self.process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let timedOut = self.didTimeout
            let cancelled = self.didCancel
            self.lock.unlock()

            if timedOut {
                self.finish(.failure(ClaudePTYRunnerError.timedOut))
            } else if cancelled {
                self.finish(.failure(ClaudePTYRunnerError.cancelled))
            } else if process.terminationStatus == 0 {
                self.finish(.success(()))
            } else {
                self.finish(.failure(ClaudePTYRunnerError.processExited(process.terminationStatus)))
            }
        }

        do {
            try self.process.run()
            self.establishProcessGroup()
            try self.master.write(contentsOf: Data("\(self.command)\r".utf8))
            self.closeParentSlave()
        } catch {
            self.closeParentSlave()
            self.fail(ClaudePTYRunnerError.launchFailed)
        }
    }

    private func timeout() {
        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return
        }
        self.didTimeout = true
        self.lock.unlock()
        self.terminate()
    }

    private func cancel() {
        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return
        }
        self.didCancel = true
        self.lock.unlock()
        self.terminate()
    }

    private func establishProcessGroup() {
        let pid = self.process.processIdentifier
        let identity = Self.identity(for: pid)
        let didSetGroup = pid > 1 && setpgid(pid, pid) == 0
        self.lock.lock()
        if !self.didFinish {
            self.rootIdentity = identity
            if didSetGroup {
                self.processGroupID = pid
            }
        }
        self.lock.unlock()
    }

    private func fail(_ error: Error) {
        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return
        }
        self.didFail = error
        self.lock.unlock()

        if self.process.isRunning {
            self.terminate()
        } else {
            self.finish(.failure(error))
        }
    }

    private func terminate() {
        self.lock.lock()
        guard !self.didFinish, !self.didTerminate else {
            self.lock.unlock()
            return
        }
        self.didTerminate = true
        let pid = self.process.processIdentifier
        let processGroupID = self.processGroupID
        let rootIdentity = self.rootIdentity
        self.capturedDescendants = Self.descendants(of: pid)
        let descendants = self.capturedDescendants
        // The shell may be waiting for a command or a prompt. Try to leave it cleanly before
        // sending signals, but never wait for this write to finish.
        try? self.master.write(contentsOf: Data("/exit\r".utf8))
        self.lock.unlock()

        self.send(
            signal: SIGTERM,
            to: processGroupID,
            root: rootIdentity,
            descendants: descendants
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let group = self.processGroupID
            let root = self.rootIdentity
            let children = self.capturedDescendants
            let shouldKill = !children.isEmpty || (!self.didFinish && self.process.isRunning)
            self.lock.unlock()
            guard shouldKill else { return }
            self.send(
                signal: SIGKILL,
                to: group,
                root: root,
                descendants: children
            )
        }
    }

    private func send(
        signal: Int32,
        to processGroupID: pid_t?,
        root: ProcessIdentity?,
        descendants: [ProcessIdentity]
    ) {
        var rootSignaled = false
        if let root, Self.matches(root) {
            if let processGroupID, processGroupID > 1,
               kill(-processGroupID, signal) == 0 {
                rootSignaled = true
            }
            if !rootSignaled {
                _ = kill(root.pid, signal)
            }
        } else if signal == SIGTERM, self.process.isRunning {
            // Identity lookup can fail for a process that is already exiting. Foundation still
            // tracks the launched child, so use it for the first graceful stop. Never reuse a
            // bare PID for the delayed SIGKILL path.
            self.process.terminate()
        }

        for identity in descendants where Self.matches(identity) {
            _ = kill(identity.pid, signal)
        }
    }

    private func closeParentSlave() {
        self.lock.lock()
        guard !self.slaveClosed else {
            self.lock.unlock()
            return
        }
        self.slaveClosed = true
        self.lock.unlock()
        try? self.slave.close()
    }

    private func closeParentMaster() {
        self.lock.lock()
        guard !self.masterClosed else {
            self.lock.unlock()
            return
        }
        self.masterClosed = true
        self.lock.unlock()
        try? self.master.close()
    }

    private static func identity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let childCount = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listchildpids(
                pid,
                rawBuffer.baseAddress,
                Int32(rawBuffer.count)
            )
        }
        guard childCount > 0 else { return [] }
        // Unlike proc_pidinfo, proc_listchildpids returns the number of PIDs, not a byte count.
        let count = min(Int(childCount), buffer.count)
        return Array(buffer.prefix(count)).filter { $0 > 1 }
    }

    private static func descendants(of rootPID: pid_t) -> [ProcessIdentity] {
        var pending = [rootPID]
        var visited: Set<pid_t> = [rootPID]
        var result: [ProcessIdentity] = []
        while let parent = pending.popLast() {
            for child in Self.childPIDs(of: parent) where visited.insert(child).inserted {
                if let identity = Self.identity(for: child) {
                    result.append(identity)
                }
                pending.append(child)
            }
        }
        return result
    }

    private static func matches(_ identity: ProcessIdentity) -> Bool {
        guard let current = Self.identity(for: identity.pid) else { return false }
        return current == identity
    }

    private func finish(_ result: Result<Void, Error>) {
        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return
        }
        self.didFinish = true
        let finalResult = self.didFail.map { Result<Void, Error>.failure($0) } ?? result
        let completion = self.completion
        self.completion = nil
        self.lock.unlock()

        self.master.readabilityHandler = nil
        self.closeParentMaster()
        self.closeParentSlave()
        // Resume exactly once. The caller's continuation is detached before cleanup, so a
        // readability callback or termination handler racing this path cannot resume it twice.
        completion?(finalResult)
    }
}
