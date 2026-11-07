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
