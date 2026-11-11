import QuotaBarCore
import Foundation

private actor CodexRefreshTransport: HTTPTransport {
    enum Reply {
        case unauthorized
        case refreshedToken
        case rateLimited
        case longRateLimit
        case forbidden
        case usage
    }

    private let replies: [Reply]
    private let gateToBlock: UsageRateLimitGate?
    private let blockBeforeReply: Int?
    private var requestCount = 0

    init(
        replies: [Reply],
        gateToBlock: UsageRateLimitGate? = nil,
        blockBeforeReply: Int? = nil
    ) {
        self.replies = replies
        self.gateToBlock = gateToBlock
        self.blockBeforeReply = blockBeforeReply
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = self.requestCount
        self.requestCount += 1
        guard self.replies.indices.contains(index) else {
            throw URLError(.badServerResponse)
        }

        if self.blockBeforeReply == index, let gateToBlock {
            await gateToBlock.recordRateLimit(.codex, retryAfter: nil)
        }

        let statusCode: Int
        let body: Data
        switch self.replies[index] {
        case .unauthorized:
            statusCode = 401
            body = Data()
        case .refreshedToken:
            statusCode = 200
            body = Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh"}"#.utf8)
        case .rateLimited:
            statusCode = 429
            body = Data()
        case .longRateLimit:
            statusCode = 429
            body = Data()
        case .forbidden:
            statusCode = 403
            body = Data()
        case .usage:
            statusCode = 200
            body = Data(#"{"rate_limit":{"primary_window":{"used_percent":12}}}"#.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: self.replies[index] == .longRateLimit ? ["Retry-After": "1800"] : nil
        )!
        return (body, response)
    }

    func requestsMade() -> Int {
        self.requestCount
    }
}

private actor CodexRotatingTransport: HTTPTransport {
    private var refreshTokens: [String] = []
    private var usageTokens: [String] = []
    private var usageAccounts: [String?] = []
    private var rejectUsage = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status: Int
        let body: String
        if request.httpMethod == "POST" {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let token = payload["refresh_token"]!
            let reused = self.refreshTokens.contains(token)
            self.refreshTokens.append(token)
            let generation = self.refreshTokens.count
            // Let overlapping polls reach the provider while the refresh is in flight.
            await Task.yield()
            status = reused ? 400 : 200
            body = reused
                ? #"{"error":{"code":"refresh_token_reused"}}"#
                : """
                  {"access_token":"test-access-\(generation)","refresh_token":"test-refresh-\(generation)"}
                  """
        } else {
            self.usageTokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            self.usageAccounts.append(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            status = self.rejectUsage ? 401 : 200
            body = #"{"rate_limit":{"primary_window":{"used_percent":12}}}"#
            self.rejectUsage = false
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!)
    }

    func rejectNextUsage() { self.rejectUsage = true }
    func refreshedTokens() -> [String] { self.refreshTokens }
    func usedTokens() -> [String] { self.usageTokens }
    func usedAccounts() -> [String?] { self.usageAccounts }
}

enum CodexRefreshTests {
    static func run() async {
        Self.retryAfterFormats()
        await Self.firstUsageSuccessClearsGate()
        await Self.retryUsageSuccessClearsGate()
        await Self.retryRateLimitStartsBackoff()
        await Self.longRateLimitIsHonored(replies: [.longRateLimit])
        await Self.longRateLimitIsHonored(replies: [.unauthorized, .refreshedToken, .longRateLimit])
        await Self.credentialReadFailureIsNotSignedOut()
        await Self.forbiddenResponseIsNotSignedOut()
        do {
            try await Self.rotatedCredentialsSurvivePolls()
        } catch {
            Harness.expect(false, "Codex credential cache regression threw: \(error)")
        }
        await Self.concurrentPollsShareRefresh()
    }

    private static func rotatedCredentialsSurvivePolls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authFile = directory.appendingPathComponent("auth.json")
        let original = Data(#"{"tokens":{"access_token":"test-expired-access","refresh_token":"test-disk-refresh","account_id":"test-account"},"last_refresh":"2000-01-01T00:00:00Z"}"#.utf8)
        try original.write(to: authFile)
        let transport = CodexRotatingTransport()
        let gate = UsageRateLimitGate()
        func fetch() async -> ProviderState {
            await CodexProvider.fetch(env: ["CODEX_HOME": directory.path], transport: transport, gate: gate)
        }

        for _ in 0..<2 {
            guard case .loaded = await fetch() else {
                Harness.expect(false, "consecutive polls load usage with rotated credentials")
                return
            }
        }
        Harness.expectEqual(await transport.refreshedTokens(), ["test-disk-refresh"],
                            "unchanged expired disk credentials refresh only once across polls")
        Harness.expectEqual(await transport.usedTokens(), ["Bearer test-access-1", "Bearer test-access-1"],
                            "later polls use the refreshed access token")
        Harness.expectEqual(try Data(contentsOf: authFile), original, "refresh never writes the CLI credential file")

        await transport.rejectNextUsage()
        guard case .loaded = await fetch(), case .loaded = await fetch() else {
            Harness.expect(false, "an expired cached access token recovers and remains cached")
            return
        }
        Harness.expectEqual(await transport.refreshedTokens(), ["test-disk-refresh", "test-refresh-1"],
                            "401 recovery exchanges the in-memory rotated refresh token")
        Harness.expectEqual(await transport.usedTokens().last, "Bearer test-access-2",
                            "401 recovery retains refreshed credentials for later polls")

        try FileManager.default.removeItem(at: authFile)
        let usageCount = await transport.usedTokens().count
        guard case .signedOut = await fetch() else {
            Harness.expect(false, "removing disk credentials reports sign-out despite the cache")
            return
        }
        Harness.expectEqual(await transport.usedTokens().count, usageCount, "sign-out makes no usage request")
        try original.write(to: authFile)
        let refreshCount = await transport.refreshedTokens().count
        _ = await fetch()
        Harness.expectEqual(await transport.refreshedTokens().count, refreshCount + 1,
                            "sign-out discards the cached session even if the same file returns")

        // Start a fresh disk identity, refresh it, then let the CLI replace it again.
        let replacement = Data(#"{"tokens":{"access_token":"test-cli-access","refresh_token":"test-cli-refresh","account_id":"test-new-account"},"last_refresh":"2099-01-01T00:00:00Z"}"#.utf8)
        try replacement.write(to: authFile)
        await transport.rejectNextUsage()
        guard case .loaded = await fetch() else {
            Harness.expect(false, "new disk credentials can establish a refreshed session")
            return
        }
        let latest = Data(#"{"tokens":{"access_token":"test-latest-access","refresh_token":"test-latest-refresh","account_id":"test-latest-account"},"last_refresh":"2099-01-01T00:00:00Z"}"#.utf8)
        try latest.write(to: authFile)
        guard case .loaded = await fetch() else {
            Harness.expect(false, "changed disk credentials load usage")
            return
        }
        Harness.expectEqual(await transport.usedTokens().last, "Bearer test-latest-access",
                            "changed disk credentials replace the cached access token")
        Harness.expectEqual(await transport.usedAccounts().last!, "test-latest-account",
                            "changed disk credentials replace the cached account")
    }

    private static func concurrentPollsShareRefresh() async {
        let transport = CodexRotatingTransport()
        let gate = UsageRateLimitGate()
        let credentials = CodexCredentials(accessToken: "test-concurrent-expired", refreshToken: "test-concurrent-refresh",
                                           accountId: "test-concurrent-account", lastRefresh: nil)
        await withTaskGroup(of: ProviderState.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await CodexProvider.fetch(env: ["CODEX_HOME": "/nonexistent"], transport: transport,
                                              gate: gate, credentialLoader: { credentials })
                }
            }
            for await state in group {
                guard case .loaded = state else {
                    Harness.expect(false, "concurrent polls load usage with a shared refresh")
                    continue
                }
            }
        }
        Harness.expectEqual(await transport.refreshedTokens(), ["test-concurrent-refresh"],
                            "concurrent polls exchange a rotating refresh token only once")
        Harness.expectEqual(await transport.usedTokens(), Array(repeating: "Bearer test-access-1", count: 10),
                            "concurrent polls all use the refreshed token")
    }

    private static func retryAfterFormats() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func parsed(_ value: String?) -> Date? {
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429,
                                           httpVersion: nil, headerFields: value.map { ["Retry-After": $0] })!
            return HTTPRetryAfter.date(from: response, now: now)
        }
        Harness.expectEqual(parsed(" 1800 "), now.addingTimeInterval(1800), "Retry-After accepts seconds")
        Harness.expectEqual(parsed("Fri, 15 Jan 2027 08:30:00 GMT"), now.addingTimeInterval(1800),
                            "Retry-After accepts an HTTP date")
        for value in [nil, "invalid", "NaN", "inf", "-1"] as [String?] {
            Harness.expectEqual(parsed(value), nil, "invalid Retry-After uses the fallback")
        }
    }

    private static func firstUsageSuccessClearsGate() async {
        let gate = UsageRateLimitGate()
        let transport = CodexRefreshTransport(
            replies: [.usage],
            gateToBlock: gate,
            blockBeforeReply: 0
        )

        let state = await Self.fetch(transport: transport, gate: gate)

        guard case .loaded = state else {
            Harness.expect(false, "a successful first usage request loads usage")
            return
        }
        Harness.expect(await gate.blocked(.codex) == nil, "a successful first usage request clears the gate")
    }

    private static func retryUsageSuccessClearsGate() async {
        let gate = UsageRateLimitGate()
        let transport = CodexRefreshTransport(
            replies: [.unauthorized, .refreshedToken, .usage],
            gateToBlock: gate,
            blockBeforeReply: 2
        )

        let state = await Self.fetch(transport: transport, gate: gate)

        guard case .loaded = state else {
            Harness.expect(false, "a successful usage retry loads usage")
            return
        }
        Harness.expect(await gate.blocked(.codex) == nil, "a successful usage retry clears the gate")
        Harness.expectEqual(await transport.requestsMade(), 3, "an unauthorized usage request retries once")
    }

    private static func retryRateLimitStartsBackoff() async {
        let gate = UsageRateLimitGate()
        let transport = CodexRefreshTransport(
            replies: [.unauthorized, .refreshedToken, .rateLimited]
        )

        let state = await Self.fetch(transport: transport, gate: gate)

        guard case let .rateLimited(_, retryAfter) = state else {
            Harness.expect(false, "a rate-limited usage retry reports its deadline")
            return
        }
        Harness.expectEqual(
            await gate.blocked(.codex), retryAfter,
            "a rate-limited usage retry reports the gate's deadline"
        )
        Harness.expectEqual(await transport.requestsMade(), 3, "a rate-limited usage request retries once")
    }

    private static func longRateLimitIsHonored(replies: [CodexRefreshTransport.Reply]) async {
        let before = Date()
        let transport = CodexRefreshTransport(replies: replies)
        let gate = UsageRateLimitGate()
        let state = await Self.fetch(transport: transport, gate: gate)
        guard case let .rateLimited(_, retryAfter) = state else {
            Harness.expect(false, "a long server rate limit reports its deadline")
            return
        }
        Harness.expect(
            (1799...1801).contains(retryAfter.timeIntervalSince(before)),
            "Codex honors Retry-After on both the initial request and the recovery retry"
        )
        Harness.expectEqual(await gate.blocked(.codex), retryAfter, "the gate retains the server deadline")
        _ = await Self.fetch(transport: transport, gate: gate)
        Harness.expectEqual(await transport.requestsMade(), replies.count, "the server deadline prevents further requests")
    }

    private static func credentialReadFailureIsNotSignedOut() async {
        let transport = CodexRefreshTransport(replies: [])
        let state = await CodexProvider.fetch(
            env: [:],
            transport: transport,
            gate: UsageRateLimitGate(),
            credentialLoader: { throw CodexCredentialsError.unreadable }
        )
        guard case let .failed(reason) = state else {
            Harness.expect(false, "unreadable credentials report a failure, not missing login")
            return
        }
        Harness.expect(reason.contains("could not be read"), "credential failure keeps its specific remedy")
        Harness.expectEqual(await transport.requestsMade(), 0, "unreadable credentials make no API call")
    }

    private static func forbiddenResponseIsNotSignedOut() async {
        let transport = CodexRefreshTransport(replies: [.forbidden])
        let state = await Self.fetch(transport: transport, gate: UsageRateLimitGate())
        guard case let .failed(reason) = state else {
            Harness.expect(false, "HTTP 403 reports a refresh failure, not missing login")
            return
        }
        Harness.expect(reason.contains("403"), "HTTP 403 keeps its status code")
    }

    private static func fetch(
        transport: CodexRefreshTransport,
        gate: UsageRateLimitGate
    ) async -> ProviderState {
        let credentials = CodexCredentials(
            accessToken: "stale-access",
            refreshToken: "stale-refresh",
            accountId: "test-account",
            lastRefresh: Date()
        )
        return await CodexProvider.fetch(
            env: ["CODEX_HOME": "/nonexistent"],
            transport: transport,
            gate: gate,
            credentialLoader: { credentials }
        )
    }
}
