// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentialModels.swift
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials+SecurityCLIReader.swift
//
// The keychain read shells out to /usr/bin/security rather than calling SecItemCopyMatching.
// That is deliberate: keychain ACLs are granted to the *requesting process*, and `security` is a
// stable Apple-signed binary, so a one-time "Always Allow" survives every rebuild of this app.
// The trade-off is that the grant then covers any process able to run `security`.

import Foundation

public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        subscriptionType: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
    }

    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }
}

public enum ClaudeCredentialsError: LocalizedError, Sendable {
    case keychainItemMissing
    case keychainReadFailed(String)
    case decodeFailed
    case missingOAuth
    case missingAccessToken

    public var errorDescription: String? {
        switch self {
        case .keychainItemMissing:
            "No Claude Code credentials in the keychain. Run `claude` to sign in."
        case let .keychainReadFailed(reason):
            "Could not read the Claude keychain item: \(reason)"
        case .decodeFailed:
            "Claude keychain payload could not be decoded."
        case .missingOAuth:
            "Claude keychain payload has no `claudeAiOauth` entry. Run `claude` to sign in."
        case .missingAccessToken:
            "Claude keychain payload has no access token. Run `claude` to sign in."
        }
    }
}

public enum ClaudeCredentialsStore {
    static let keychainService = "Claude Code-credentials"
    private static let securityBinaryPath = "/usr/bin/security"
    private static let readTimeout: TimeInterval = 10

    public static func load() throws -> ClaudeCredentials {
        let payload = try Self.readKeychainPayload()
        return try Self.parse(data: payload)
    }

    public static func parse(data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else {
            throw ClaudeCredentialsError.decodeFailed
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeCredentialsError.missingOAuth
        }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw ClaudeCredentialsError.missingAccessToken
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth.refreshToken,
            // Claude Code stores the expiry as epoch milliseconds.
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) },
            scopes: oauth.scopes ?? [],
            subscriptionType: oauth.subscriptionType
        )
    }

    private static func readKeychainPayload() throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: Self.securityBinaryPath) else {
            throw ClaudeCredentialsError.keychainReadFailed("/usr/bin/security is unavailable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.securityBinaryPath)
        process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            throw ClaudeCredentialsError.keychainReadFailed("could not launch security: \(error.localizedDescription)")
        }

        // `security` blocks on the keychain prompt, so the timeout has to be generous enough
        // for a human to click "Always Allow" the first time.
        let deadline = Date().addingTimeInterval(Self.readTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw ClaudeCredentialsError.keychainReadFailed("timed out after \(Int(Self.readTimeout))s")
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 44 is SecurityAgent's "item not found"; 128 is the user cancelling the prompt.
            if message.contains("could not be found") {
                throw ClaudeCredentialsError.keychainItemMissing
            }
            throw ClaudeCredentialsError.keychainReadFailed(
                message.isEmpty ? "exit status \(process.terminationStatus)" : message
            )
        }

        guard let text = String(data: out, encoding: .utf8) else {
            throw ClaudeCredentialsError.decodeFailed
        }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let subscriptionType: String?
    }
}
