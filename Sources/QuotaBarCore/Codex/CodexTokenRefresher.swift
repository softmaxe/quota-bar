// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift

import Foundation

public enum CodexTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public enum RefreshError: LocalizedError, Sendable {
        case expired
        case revoked
        case reused
        case networkError(String)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                "Codex refresh token expired. Run `codex login` to sign in again."
            case .revoked:
                "Codex refresh token was revoked. Run `codex login` to sign in again."
            case .reused:
                "Codex refresh token was already used. Run `codex login` to sign in again."
            case let .networkError(message):
                "Network error during Codex token refresh: \(message)"
            case let .invalidResponse(message):
                "Invalid Codex refresh response: \(message)"
            }
        }
    }

    /// Exchanges the refresh token for a fresh access token. The result is kept in memory only —
    /// auth.json belongs to the Codex CLI.
    public static func refresh(
        _ credentials: CodexCredentials,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> CodexCredentials {
        guard !credentials.refreshToken.isEmpty else { return credentials }

        var request = URLRequest(
            url: Self.refreshEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw RefreshError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw Self.failureError(statusCode: response.statusCode, data: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse("Invalid JSON")
        }

        return CodexCredentials(
            accessToken: json["access_token"] as? String ?? credentials.accessToken,
            refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
            accountId: credentials.accountId,
            lastRefresh: Date()
        )
    }

    private static func failureError(statusCode: Int, data: Data) -> RefreshError {
        if let code = Self.errorCode(from: data) {
            switch code.lowercased() {
            case "refresh_token_expired": return .expired
            case "refresh_token_reused": return .reused
            case "invalid_grant", "refresh_token_invalidated": return .revoked
            default: break
            }
        }
        if statusCode == 401 { return .expired }
        return .invalidResponse("Status \(statusCode)")
    }

    private static func errorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String { return code }
        if let error = json["error"] as? String { return error }
        return json["code"] as? String
    }
}
