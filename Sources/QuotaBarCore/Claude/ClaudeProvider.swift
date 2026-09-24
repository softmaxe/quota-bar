import Foundation

/// Identifies whether a provider refresh came from an automatic poll or a user action.
public enum ClaudeRefreshInteraction: Sendable {
    case automatic
    case userInitiated
}

/// Reads the credentials owned by Claude Code without changing them.
public typealias ClaudeCredentialLoader = @Sendable () throws -> ClaudeCredentials

/// Asks Claude Code to perform its own credential refresh. The refresher receives no credential
/// payload; the provider reads the credentials again afterward.
public typealias ClaudeDelegatedRefresher = @Sendable () async throws -> Void

/// Reads the keychain credential and maps `/api/oauth/usage` onto a `UsageSnapshot`.
public enum ClaudeProvider {
    public static func fetch(
        transport: any HTTPTransport = URLSessionTransport(),
        gate: UsageRateLimitGate = .shared,
        interaction: ClaudeRefreshInteraction = .automatic,
        credentialLoader: @escaping ClaudeCredentialLoader = { try ClaudeCredentialsStore.load() },
        delegatedRefresher: @escaping ClaudeDelegatedRefresher = {
            try await ClaudeDelegatedRefreshCoordinator.shared.refresh()
        }
    ) async -> ProviderState {
        // Refuse to spend a request while a previous 429 is still in force.
        if let until = await gate.blocked(.claude) {
            return .rateLimited(
                reason: ClaudeFetchError.rateLimited(until).localizedDescription,
                retryAfter: until
            )
        }

        let credentials: ClaudeCredentials
        do {
            credentials = try credentialLoader()
        } catch let error as ClaudeCredentialsError {
            switch error {
            case .keychainItemMissing, .missingOAuth, .missingAccessToken:
                return .signedOut(error.localizedDescription)
            case .keychainAccessDenied:
                return .accessDenied(error.localizedDescription)
            case .keychainReadFailed, .decodeFailed:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        if credentials.isExpired {
            // The usage response remains authoritative. A user-initiated 401 may delegate the
            // refresh to Claude Code; automatic refreshes stay fail-closed.
            Log.claude.warning("Claude access token is past its expiry; the usage call may 401")
        }

        do {
            let response = try await ClaudeUsageFetcher.fetchUsage(
                accessToken: credentials.accessToken,
                transport: transport
            )
            await gate.recordSuccess(.claude)
            return .loaded(Self.snapshot(from: response, credentials: credentials))
        } catch let error as ClaudeFetchError {
            if case let .rateLimited(retryAfter) = error {
                await gate.recordRateLimit(.claude, retryAfter: retryAfter)
                let until = await gate.blocked(.claude) ?? Date().addingTimeInterval(5 * 60)
                return .rateLimited(
                    reason: ClaudeFetchError.rateLimited(until).localizedDescription,
                    retryAfter: until
                )
            }
            guard case .unauthorized = error else {
                return .failed(error.localizedDescription)
            }
            return await Self.recoverAfterUnauthorized(
                originalCredentials: credentials,
                interaction: interaction,
                transport: transport,
                gate: gate,
                credentialLoader: credentialLoader,
                delegatedRefresher: delegatedRefresher
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func recoverAfterUnauthorized(
        originalCredentials: ClaudeCredentials,
        interaction: ClaudeRefreshInteraction,
        transport: any HTTPTransport,
        gate: UsageRateLimitGate,
        credentialLoader: @escaping ClaudeCredentialLoader,
        delegatedRefresher: @escaping ClaudeDelegatedRefresher
    ) async -> ProviderState {
        // A different token may already have been written by Claude Code while the usage call
        // was in flight. Always reread before asking Claude Code to do anything else.
        let preRetryCredentials: ClaudeCredentials
        do {
            preRetryCredentials = try credentialLoader()
        } catch {
            return .failed("Claude credential recovery could not reread credentials.")
        }

        if preRetryCredentials.accessToken != originalCredentials.accessToken {
            return await Self.retryUsage(
                credentials: preRetryCredentials,
                transport: transport,
                gate: gate
            )
        }

        guard interaction == .userInitiated else {
            return .recoveryRequired(
                "Claude credentials need recovery. Click Refresh to let Claude Code update them."
            )
        }

        var delegatedError: Error?
        do {
            try await delegatedRefresher()
        } catch {
            // Still reread below. Claude Code may have updated the keychain before reporting an
            // exit error, and the access-token change is the only success signal we trust.
            delegatedError = error
        }

        let postRefreshCredentials: ClaudeCredentials
        do {
            postRefreshCredentials = try credentialLoader()
        } catch {
            return .failed(Self.recoveryFailure(delegatedError))
        }

        guard postRefreshCredentials.accessToken != originalCredentials.accessToken else {
            return .failed(Self.recoveryFailure(delegatedError))
        }

        return await Self.retryUsage(
            credentials: postRefreshCredentials,
            transport: transport,
            gate: gate
        )
    }

    private static func retryUsage(
        credentials: ClaudeCredentials,
        transport: any HTTPTransport,
        gate: UsageRateLimitGate
    ) async -> ProviderState {
        // This is the one and only retry.
        do {
            let response = try await ClaudeUsageFetcher.fetchUsage(
                accessToken: credentials.accessToken,
                transport: transport
            )
            await gate.recordSuccess(.claude)
            return .loaded(Self.snapshot(from: response, credentials: credentials))
        } catch let error as ClaudeFetchError {
            if case let .rateLimited(retryAfter) = error {
                await gate.recordRateLimit(.claude, retryAfter: retryAfter)
                let until = await gate.blocked(.claude) ?? Date().addingTimeInterval(5 * 60)
                return .rateLimited(
                    reason: ClaudeFetchError.rateLimited(until).localizedDescription,
                    retryAfter: until
                )
            }
            if case .unauthorized = error {
                return .failed("Claude credential recovery produced a token the usage API rejected.")
            }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func recoveryFailure(_ delegatedError: Error?) -> String {
        guard let delegatedError else {
            return "Claude credential recovery did not update credentials. Try Refresh again."
        }
        if let error = delegatedError as? ClaudeDelegatedRefreshError {
            switch error {
            case .automaticNotAllowed:
                return "Claude credential recovery is disabled for automatic refreshes."
            case .cooldown:
                return "Claude credential recovery did not update credentials. Try Refresh again shortly."
            case .alreadyRunning:
                return "Claude credential recovery is already in progress. Try Refresh again shortly."
            case .cliUnavailable:
                return "Claude credential recovery unavailable: Claude CLI was not found."
            case .timedOut:
                return "Claude credential recovery did not update credentials before the timeout."
            case .processFailed:
                return "Claude credential recovery did not update credentials."
            }
        }
        return "Claude credential recovery did not update credentials."
    }

    public static func snapshot(
        from response: ClaudeUsageResponse,
        credentials: ClaudeCredentials,
        now: Date = Date()
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            session: response.fiveHour?.window,
            weekly: response.sevenDay?.window,
            planLabel: credentials.subscriptionType.map(Self.planLabel),
            credits: nil,
            fetchedAt: now
        )
    }

    public static func planLabel(_ raw: String) -> String {
        PlanLabel.humanize(raw)
    }
}
