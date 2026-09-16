import QuotaBarCore
import Darwin
import Foundation

private final class ClaudeRefreshFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: ClaudeCredentials
    private var queuedCredentials: [ClaudeCredentials] = []
    private var credentialLoads = 0
    private var delegatedRefreshes = 0
    private var requestedTokens: [String] = []

    init(credentials: ClaudeCredentials) {
        self.credentials = credentials
    }

    func loadCredentials() -> ClaudeCredentials {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.credentialLoads += 1
        if self.credentialLoads > 1, !self.queuedCredentials.isEmpty {
            self.credentials = self.queuedCredentials.removeFirst()
        }
        return self.credentials
    }

    func queueCredentials(_ credentials: [ClaudeCredentials]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.queuedCredentials.append(contentsOf: credentials)
    }

    func recordDelegatedRefresh(to credentials: ClaudeCredentials) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.delegatedRefreshes += 1
        self.credentials = credentials
    }

    func recordRequest(token: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requestedTokens.append(token)
    }

    var loadCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.credentialLoads
    }

    var delegatedRefreshCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.delegatedRefreshes
    }

    var tokens: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requestedTokens
    }
}

private struct ClaudeRefreshTransport: HTTPTransport {
    let fixture: ClaudeRefreshFixture
    let alwaysUnauthorized: Bool

    init(fixture: ClaudeRefreshFixture, alwaysUnauthorized: Bool = false) {
        self.fixture = fixture
        self.alwaysUnauthorized = alwaysUnauthorized
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        self.fixture.recordRequest(token: token)

        let statusCode = self.alwaysUnauthorized || token == "Bearer stale-token" ? 401 : 200
        let body = statusCode == 200
            ? Data(#"{"five_hour":{"utilization":12}}"#.utf8)
            : Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

enum ClaudeRefreshTests {
    static func run() async {
        await Self.manualRefreshUsesTokenChangedDuringPreReload()
        await Self.manualRefreshDelegatesAfterUnauthorized()
        await Self.automaticRefreshDoesNotDelegate()
        await Self.manualRefreshStopsWhenDelegationDoesNotChangeCredentials()
        await Self.manualRefreshReportsCLIUnavailable()
        await Self.manualRefreshStopsAfterRetryUnauthorized()
        await Self.coordinatorPolicy()
        await Self.coordinatorCooldownAndRequest()
        await Self.coordinatorSingleFlight()
        await Self.localPTYRunner()
        await Self.localPTYTimeout()
        await Self.localPTYTimeoutCleansChildTree()
        Self.environmentSanitization()
        Self.cliLocator()
    }

    private static func manualRefreshUsesTokenChangedDuringPreReload() async {
        let staleCredentials = Self.credentials(accessToken: "stale-token", expiresIn: -60)
        let freshCredentials = Self.credentials(accessToken: "fresh-token", expiresIn: 3_600)
        let fixture = ClaudeRefreshFixture(credentials: staleCredentials)
        fixture.queueCredentials([freshCredentials])

        let state = await ClaudeProvider.fetch(
            transport: ClaudeRefreshTransport(fixture: fixture),
            gate: UsageRateLimitGate(),
            interaction: .userInitiated,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: {
                fixture.recordDelegatedRefresh(to: staleCredentials)
            }
        )

        Harness.expectEqual(
            fixture.delegatedRefreshCount,
            0,
            "a changed pre-reload token skips delegated refresh"
        )
        Harness.expectEqual(fixture.loadCount, 2, "a changed pre-reload token is loaded once")
        Harness.expectEqual(
            fixture.tokens,
            ["Bearer stale-token", "Bearer fresh-token"],
            "a changed pre-reload token is retried directly"
        )
        guard case let .loaded(snapshot) = state else {
            Harness.expect(false, "a changed pre-reload token recovers usage")
            return
        }
        Harness.expectEqual(snapshot.session?.usedPercent, 12, "direct retry decodes usage")
    }

    private static func manualRefreshDelegatesAfterUnauthorized() async {
        let staleCredentials = ClaudeCredentials(
            accessToken: "stale-token", refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSinceNow: -60), scopes: [], subscriptionType: "pro"
        )
        let freshCredentials = ClaudeCredentials(
            accessToken: "fresh-token",
            refreshToken: "fresh-refresh-token",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            scopes: [],
            subscriptionType: "pro"
        )
        let fixture = ClaudeRefreshFixture(credentials: staleCredentials)
        let transport = ClaudeRefreshTransport(fixture: fixture)

        let state = await ClaudeProvider.fetch(
            transport: transport,
            gate: UsageRateLimitGate(),
            interaction: .userInitiated,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: { fixture.recordDelegatedRefresh(to: freshCredentials) }
        )

        Harness.expectEqual(
            fixture.delegatedRefreshCount,
            1,
            "a user refresh delegates after the first unauthorized usage response"
        )
        Harness.expectEqual(fixture.loadCount, 3, "a user refresh rereads credentials before and after delegation")
        Harness.expectEqual(
            fixture.tokens,
            ["Bearer stale-token", "Bearer fresh-token"],
            "the retry uses the reread access token"
        )
        guard case let .loaded(snapshot) = state else {
            Harness.expect(false, "a user refresh succeeds after Claude Code updates credentials")
            return
        }
        Harness.expectEqual(snapshot.session?.usedPercent, 12, "the retry decodes usage")
    }

    private static func automaticRefreshDoesNotDelegate() async {
        let credentials = ClaudeCredentials(
            accessToken: "stale-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSinceNow: -60),
            scopes: [],
            subscriptionType: "pro"
        )
        let fixture = ClaudeRefreshFixture(credentials: credentials)
        let state = await ClaudeProvider.fetch(
            transport: ClaudeRefreshTransport(fixture: fixture),
            gate: UsageRateLimitGate(),
            interaction: .automatic,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: { fixture.recordDelegatedRefresh(to: credentials) }
        )

        Harness.expectEqual(
            fixture.delegatedRefreshCount,
            0,
            "an automatic refresh never delegates after unauthorized usage"
        )
        Harness.expectEqual(fixture.loadCount, 2, "an automatic unauthorized refresh rereads once")
        Harness.expectEqual(fixture.tokens, ["Bearer stale-token"], "automatic refresh makes one request")
        guard case .recoveryRequired = state else {
            Harness.expect(false, "an automatic unauthorized refresh offers explicit recovery")
            return
        }
    }

    private static func manualRefreshStopsWhenDelegationDoesNotChangeCredentials() async {
        let credentials = Self.credentials(accessToken: "stale-token", expiresIn: -60)
        let fixture = ClaudeRefreshFixture(credentials: credentials)
        let state = await ClaudeProvider.fetch(
            transport: ClaudeRefreshTransport(fixture: fixture),
            gate: UsageRateLimitGate(),
            interaction: .userInitiated,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: { fixture.recordDelegatedRefresh(to: credentials) }
        )

        Harness.expectEqual(fixture.delegatedRefreshCount, 1, "manual recovery delegates once")
        Harness.expectEqual(fixture.loadCount, 3, "manual recovery reloads before and after delegation")
        Harness.expectEqual(fixture.tokens, ["Bearer stale-token"], "unchanged credentials are not retried")
        guard case let .failed(reason) = state else {
            Harness.expect(false, "unchanged credentials leave manual recovery failed")
            return
        }
        Harness.expect(
            reason.contains("did not update credentials"),
            "unchanged credentials explain that recovery did not update credentials"
        )
    }

    private static func manualRefreshReportsCLIUnavailable() async {
        let credentials = Self.credentials(accessToken: "stale-token", expiresIn: -60)
        let fixture = ClaudeRefreshFixture(credentials: credentials)
        let state = await ClaudeProvider.fetch(
            transport: ClaudeRefreshTransport(fixture: fixture),
            gate: UsageRateLimitGate(),
            interaction: .userInitiated,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: { throw ClaudeDelegatedRefreshError.cliUnavailable }
        )

        guard case let .failed(reason) = state else {
            Harness.expect(false, "an unavailable CLI leaves manual recovery failed")
            return
        }
        Harness.expect(
            reason.contains("Claude CLI was not found"),
            "an unavailable CLI is reported without claiming the account is signed out"
        )
    }

    private static func manualRefreshStopsAfterRetryUnauthorized() async {
        let staleCredentials = Self.credentials(accessToken: "stale-token", expiresIn: -60)
        let freshCredentials = Self.credentials(accessToken: "fresh-token", expiresIn: 3_600)
        let fixture = ClaudeRefreshFixture(credentials: staleCredentials)
        let state = await ClaudeProvider.fetch(
            transport: ClaudeRefreshTransport(fixture: fixture, alwaysUnauthorized: true),
            gate: UsageRateLimitGate(),
            interaction: .userInitiated,
            credentialLoader: { fixture.loadCredentials() },
            delegatedRefresher: { fixture.recordDelegatedRefresh(to: freshCredentials) }
        )

        Harness.expectEqual(fixture.delegatedRefreshCount, 1, "manual recovery delegates once before retry")
        Harness.expectEqual(fixture.loadCount, 3, "retry-unauthorized recovery reloads only twice")
        Harness.expectEqual(
            fixture.tokens,
            ["Bearer stale-token", "Bearer fresh-token"],
            "retry-unauthorized recovery makes one retry"
        )
        guard case let .failed(reason) = state else {
            Harness.expect(false, "a second unauthorized response stops recovery")
            return
        }
        Harness.expect(reason.contains("rejected"), "a rejected retry is classified as recovery failure")
    }

    private static func coordinatorPolicy() async {
        let runner = ClaudeRecordingRunner()
        let coordinator = ClaudeDelegatedRefreshCoordinator(
            runner: runner,
            locator: ClaudeCLILocator(isExecutable: { _ in true }),
            environment: ["CLAUDE_CLI_PATH": "/fake/claude"]
        )

        do {
            try await coordinator.refresh(interaction: .automatic)
            Harness.expect(false, "automatic coordinator refresh is rejected")
        } catch let error as ClaudeDelegatedRefreshError {
            Harness.expectEqual(error, .automaticNotAllowed, "automatic coordinator refresh is fail-closed")
        } catch {
            Harness.expect(false, "automatic coordinator refresh reports the expected policy error")
        }
    }

    private static func coordinatorCooldownAndRequest() async {
        let clock = ClaudeRefreshClock(value: 100)
        let runner = ClaudeRecordingRunner()
        let coordinator = ClaudeDelegatedRefreshCoordinator(
            runner: runner,
            locator: ClaudeCLILocator(isExecutable: { $0 == "/fake/claude" }),
            environment: [
                "CLAUDE_CLI_PATH": "/fake/claude",
                "CLAUDE_CONFIG_DIR": "/profile",
                "ANTHROPIC_API_KEY": "secret",
                "PATH": "/bin",
            ],
            now: { clock.now() }
        )

        do {
            try await coordinator.refresh()
        } catch {
            Harness.expect(false, "a manual coordinator refresh succeeds with a fake runner")
        }
        do {
            try await coordinator.refresh()
            Harness.expect(false, "a second refresh inside cooldown is rejected")
        } catch let error as ClaudeDelegatedRefreshError {
            Harness.expectEqual(error, .cooldown, "a second refresh is cooldown-gated")
        } catch {
            Harness.expect(false, "cooldown reports the expected policy error")
        }

        clock.advance(by: 30)
        do {
            try await coordinator.refresh()
        } catch {
            Harness.expect(false, "a refresh after cooldown succeeds")
        }

        let requests = runner.requests
        Harness.expectEqual(requests.count, 2, "cooldown permits exactly two attempts")
        guard let request = requests.first else { return }
        Harness.expectEqual(request.executablePath, "/fake/claude", "locator path reaches the runner")
        Harness.expectEqual(request.command, "/status", "runner receives the status command separately")
        Harness.expect(!request.arguments.contains("/status"), "status is not passed as a prompt argument")
        Harness.expect(request.arguments.contains("--strict-mcp-config"), "runner disables MCP config")
        Harness.expect(request.arguments.contains("--allowed-tools"), "runner receives an empty tool allowlist")
        Harness.expect(request.arguments.contains(ClaudeDelegatedRefreshCoordinator.stableSessionID), "runner receives a stable session")
        Harness.expectEqual(request.environment["CLAUDE_CONFIG_DIR"], "/profile", "profile environment is preserved")
        Harness.expectEqual(request.environment["ANTHROPIC_API_KEY"], nil, "Anthropic environment is removed")
        Harness.expectEqual(request.environment["DISABLE_AUTOUPDATER"], "1", "autoupdater is disabled")
        Harness.expectEqual(request.environment["TERM"], "xterm-256color", "PTY environment supplies TERM")
        Harness.expectEqual(request.workingDirectoryPath, "/", "runner never starts in a user project")
        Harness.expectEqual(request.timeout, 5, "runner receives the five-second timeout")
    }

    private static func coordinatorSingleFlight() async {
        let runner = ClaudeBlockingRunner()
        let coordinator = ClaudeDelegatedRefreshCoordinator(
            runner: runner,
            locator: ClaudeCLILocator(isExecutable: { _ in true }),
            environment: ["CLAUDE_CLI_PATH": "/fake/claude"]
        )

        let first = Task {
            try? await coordinator.refresh()
        }
        await runner.waitUntilStarted()

        do {
            try await coordinator.refresh()
            Harness.expect(false, "a second concurrent refresh is rejected")
        } catch let error as ClaudeDelegatedRefreshError {
            Harness.expectEqual(error, .alreadyRunning, "single-flight rejects a concurrent refresh")
        } catch {
            Harness.expect(false, "single-flight reports the expected policy error")
        }

        await runner.release()
        _ = await first.value
        Harness.expectEqual(await runner.startCount, 1, "single-flight starts one runner")
    }

    private static func localPTYRunner() async {
        let request = ClaudeDelegatedRefreshRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r command && test \"$command\" = /status"],
            command: "/status",
            environment: ["TERM": "xterm-256color"],
            workingDirectoryPath: "/",
            timeout: 1
        )

        do {
            try await ClaudePTYRunner().run(request)
        } catch {
            Harness.expect(false, "the local PTY delivers /status and exits normally: \(error)")
        }
    }

    private static func localPTYTimeout() async {
        let request = ClaudeDelegatedRefreshRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "while :; do :; done"],
            command: "/status",
            environment: ["TERM": "xterm-256color"],
            workingDirectoryPath: "/",
            timeout: 0.1
        )
        let startedAt = Date()

        do {
            try await ClaudePTYRunner().run(request)
            Harness.expect(false, "the local PTY timeout terminates the process")
        } catch let error as ClaudePTYRunnerError {
            Harness.expectEqual(error, .timedOut, "the local PTY timeout reports timedOut")
        } catch {
            Harness.expect(false, "the local PTY timeout reports a typed timeout")
        }

        Harness.expect(
            Date().timeIntervalSince(startedAt) < 2,
            "the local PTY timeout completes promptly"
        )
    }

    private static func localPTYTimeoutCleansChildTree() async {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-pty-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let request = ClaudeDelegatedRefreshRequest(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "sleep 30 & child=$!; printf '%s\\n' \"$child\" > \"$PID_FILE\"; trap 'wait \"$child\"; exit 143' TERM INT; while :; do :; done",
            ],
            command: "/status",
            environment: ["TERM": "xterm-256color", "PID_FILE": pidFile.path],
            workingDirectoryPath: "/",
            timeout: 0.5
        )
        let runTask = Task { () -> ClaudePTYRunnerError? in
            do {
                try await ClaudePTYRunner().run(request)
                return nil
            } catch let error as ClaudePTYRunnerError {
                return error
            } catch {
                return nil
            }
        }

        let childPID = await Self.waitForPID(in: pidFile)
        let childIdentity = childPID.flatMap(Self.processIdentity)
        let result = await runTask.value

        Harness.expectEqual(result, .timedOut, "a PTY timeout with a child reports timedOut")
        guard let childIdentity else {
            Harness.expect(false, "the local child-tree fixture wrote a child identity")
            return
        }
        Harness.expect(
            await Self.waitForProcessToDisappear(childIdentity),
            "the timed-out PTY cleans up the captured child process"
        )
    }

    private static func waitForPID(in file: URL) async -> pid_t? {
        for _ in 0..<100 {
            if let raw = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private static func waitForProcessToDisappear(_ identity: LocalProcessIdentity) async -> Bool {
        for _ in 0..<200 {
            guard let current = Self.processIdentity(identity.pid) else { return true }
            if current != identity || current.status == UInt32(SZOMB) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private struct LocalProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let status: UInt32
    }

    private static func processIdentity(_ pid: pid_t) -> LocalProcessIdentity? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return LocalProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            status: info.pbi_status
        )
    }

    private static func environmentSanitization() {
        let sanitized = ClaudeDelegatedRefreshEnvironment.sanitized([
            "ANTHROPIC_API_KEY": "secret",
            "ANTHROPIC_BASE_URL": "https://example.invalid",
            "CLAUDE_CONFIG_DIR": "/profile",
            "DISABLE_AUTOUPDATER": "0",
        ])
        Harness.expectEqual(sanitized["ANTHROPIC_API_KEY"], nil, "API keys are removed from the delegated environment")
        Harness.expectEqual(sanitized["ANTHROPIC_BASE_URL"], nil, "Anthropic endpoints are removed from the delegated environment")
        Harness.expectEqual(sanitized["CLAUDE_CONFIG_DIR"], "/profile", "Claude profile variables remain")
        Harness.expectEqual(sanitized["DISABLE_AUTOUPDATER"], "1", "the updater is disabled")
    }

    private static func cliLocator() {
        let override = ClaudeCLILocator(isExecutable: { $0 == "/custom/claude" })
        Harness.expectEqual(
            override.locate(in: ["CLAUDE_CLI_PATH": "/custom/claude", "PATH": "/other"]),
            "/custom/claude",
            "CLAUDE_CLI_PATH takes precedence"
        )

        let path = ClaudeCLILocator(isExecutable: { $0 == "/bin/claude" })
        Harness.expectEqual(
            path.locate(in: ["PATH": "/usr/bin:/bin"]),
            "/bin/claude",
            "PATH is searched for Claude CLI"
        )

        let homebrew = ClaudeCLILocator(isExecutable: { $0 == "/opt/homebrew/bin/claude" })
        Harness.expectEqual(
            homebrew.locate(in: [:]),
            "/opt/homebrew/bin/claude",
            "the common Homebrew path is searched"
        )
    }

    private static func credentials(accessToken: String, expiresIn: TimeInterval) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSinceNow: expiresIn),
            scopes: [],
            subscriptionType: "pro"
        )
    }
}

private final class ClaudeRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: TimeInterval

    init(value: TimeInterval) {
        self.valueStorage = value
    }

    func now() -> TimeInterval {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.valueStorage
    }

    func advance(by amount: TimeInterval) {
        self.lock.lock()
        self.valueStorage += amount
        self.lock.unlock()
    }
}

private final class ClaudeRecordingRunner: @unchecked Sendable, ClaudeDelegatedRefreshRunner {
    private let lock = NSLock()
    private var requestStorage: [ClaudeDelegatedRefreshRequest] = []

    func run(_ request: ClaudeDelegatedRefreshRequest) async throws {
        self.record(request)
    }

    private func record(_ request: ClaudeDelegatedRefreshRequest) {
        self.lock.lock()
        self.requestStorage.append(request)
        self.lock.unlock()
    }

    var requests: [ClaudeDelegatedRefreshRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requestStorage
    }
}

private actor ClaudeBlockingRunner: ClaudeDelegatedRefreshRunner {
    private(set) var startCount = 0
    private var started: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_: ClaudeDelegatedRefreshRequest) async throws {
        self.startCount += 1
        self.started?.resume()
        self.started = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard self.startCount == 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.started = continuation
        }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
