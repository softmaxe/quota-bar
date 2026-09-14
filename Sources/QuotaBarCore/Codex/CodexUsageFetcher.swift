// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift
// Kept: the `wham/usage` request and the primary/secondary window + credits decoding.
// Dropped: spend controls, reset credits, additional per-model rate limits, workspace resolution.

import Foundation

public struct CodexUsageResponse: Decodable, Sendable {
    public let planType: String?
    public let rateLimit: RateLimit?
    public let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        self.credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
    }

    public struct RateLimit: Decodable, Sendable {
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        // A malformed window must not discard its sibling, so decode each independently.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.primaryWindow = try? container.decodeIfPresent(Window.self, forKey: .primaryWindow)
            self.secondaryWindow = try? container.decodeIfPresent(Window.self, forKey: .secondaryWindow)
        }
    }

    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let resetAt: Int?
        public let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
            self.resetAt = try? container.decodeIfPresent(Int.self, forKey: .resetAt)
            self.limitWindowSeconds = try? container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        }

        public var window: UsageWindow {
            UsageWindow(
                usedPercent: self.usedPercent,
                resetsAt: self.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                windowSeconds: self.limitWindowSeconds
            )
        }
    }

    public struct Credits: Decodable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
            self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
            if let balance = try? container.decode(Double.self, forKey: .balance) {
                self.balance = balance
            } else if let raw = try? container.decode(String.self, forKey: .balance) {
                self.balance = Double(raw)
            } else {
                self.balance = nil
            }
        }
    }
}

public enum CodexFetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Codex OAuth token expired or invalid. Run `codex login` to re-authenticate."
        case .invalidResponse:
            "Invalid response from the Codex usage API."
        case let .serverError(code, message):
            if let message, !message.isEmpty {
                "Codex API error \(code): \(message)"
            } else {
                "Codex API error \(code)."
            }
        case let .networkError(message):
            "Network error: \(message)"
        }
    }
}

public enum CodexUsageFetcher {
    private static let defaultBaseURL = "https://chatgpt.com/backend-api"
    private static let chatGPTUsagePath = "/wham/usage"
    private static let codexUsagePath = "/api/codex/usage"

    public static func fetchUsage(
        accessToken: String,
        accountId: String?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> CodexUsageResponse {
        var request = URLRequest(
            url: Self.usageURL(env: env),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw CodexFetchError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200...299:
            guard let decoded = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
                throw CodexFetchError.invalidResponse
            }
            return decoded
        case 401:
            throw CodexFetchError.unauthorized
        case 403:
            throw CodexFetchError.serverError(403, String(data: data, encoding: .utf8))
        default:
            throw CodexFetchError.serverError(response.statusCode, String(data: data, encoding: .utf8))
        }
    }

    /// `chatgpt_base_url` in config.toml can point at a proxy; the usage path differs
    /// depending on whether that base already includes `/backend-api`.
    public static func usageURL(env: [String: String]) -> URL {
        let base = Self.normalizedBaseURL(Self.configuredBaseURL(env: env))
        let path = base.contains("/backend-api") ? Self.chatGPTUsagePath : Self.codexUsagePath
        return URL(string: base + path) ?? URL(string: Self.defaultBaseURL + Self.chatGPTUsagePath)!
    }

    private static func configuredBaseURL(env: [String: String]) -> String {
        guard let contents = Self.configContents(env: env),
              let parsed = Self.parseBaseURL(from: contents) else {
            return Self.defaultBaseURL
        }
        return parsed
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = Self.defaultBaseURL }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com"),
           !trimmed.contains("/backend-api") {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private static func parseBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func configContents(env: [String: String]) -> String? {
        let root = CodexHome.url(env: env)
        return try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)
    }
}
