// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift
// Kept: the /api/oauth/usage request and the five-hour / seven-day window decoding.
// Dropped: profile lookup, per-model scoped limits, extra-usage billing, the web fallback.

import Foundation

public struct ClaudeUsageResponse: Decodable, Sendable {
    public let fiveHour: Window?
    public let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
        self.sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
    }

    public struct Window: Decodable, Sendable {
        /// Fraction of the window consumed. The API reports 0...100, not 0...1.
        public let utilization: Double?
        public let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        public var window: UsageWindow {
            UsageWindow(
                usedPercent: self.utilization ?? 0,
                resetsAt: self.resetsAt.flatMap(ISO8601.parse),
                windowSeconds: nil
            )
        }
    }
}

public enum ClaudeFetchError: LocalizedError, Sendable {
    case unauthorized
    case rateLimited(Date?)
    case invalidResponse
    case serverError(Int, String?)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Claude OAuth request unauthorized. Run `claude` to re-authenticate."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Claude usage API rate-limited. Try again after \(retryAfter.formatted(date: .omitted, time: .shortened))."
            } else {
                "Claude usage API rate-limited. Try again in a few minutes."
            }
        case .invalidResponse:
            "Claude OAuth response was invalid."
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                "Claude OAuth error: HTTP \(code) – \(Self.shorten(body))"
            } else {
                "Claude OAuth error: HTTP \(code)"
            }
        case let .networkError(message):
            "Claude OAuth network error: \(message)"
        }
    }

    private static func shorten(_ body: String) -> String {
        let cleaned = body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 400 ? String(cleaned.prefix(400)) + "…" : cleaned
    }
}

public enum ClaudeUsageFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let claudeCodeVersion = "2.1.0"

    public static func fetchUsage(
        accessToken: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> ClaudeUsageResponse {
        var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The OAuth usage endpoint is gated behind this beta header.
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ClaudeFetchError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
                throw ClaudeFetchError.invalidResponse
            }
            return decoded
        case 401:
            throw ClaudeFetchError.unauthorized
        case 429:
            throw ClaudeFetchError.rateLimited(Self.retryAfter(from: response))
        default:
            throw ClaudeFetchError.serverError(response.statusCode, String(data: data, encoding: .utf8))
        }
    }

    private static func retryAfter(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }
}
