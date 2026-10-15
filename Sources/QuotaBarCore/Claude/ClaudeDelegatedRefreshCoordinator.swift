// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift
// Kept: delegated, user-triggered CLI refresh and the ownership boundary around Claude Code's
// credentials. This app supplies its own minimal PTY runner and does not parse CLI output.

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
