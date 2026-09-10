import Foundation

public typealias CodexCredentialLoader = @Sendable () throws -> CodexCredentials

/// Loads credentials, refreshes when stale, and maps `wham/usage` onto a `UsageSnapshot`.
public enum CodexProvider {
    public static func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(),
        gate: UsageRateLimitGate = .shared,
        credentialLoader: CodexCredentialLoader? = nil
    ) async -> ProviderState {
        if let until = await gate.blocked(.codex) {
            return .failed("Codex usage API rate-limited. Try again after "
                + until.formatted(date: .omitted, time: .shortened) + ".")
        }

        var credentials: CodexCredentials
        do {
            credentials = try credentialLoader?() ?? CodexCredentialsStore.load(env: env)
        } catch let error as CodexCredentialsError {
            switch error {
            case .notFound, .missingTokens:
                return .signedOut(error.localizedDescription)
            case .unreadable, .decodeFailed:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        if credentials.needsRefresh {
            do {
                credentials = try await CodexTokenRefresher.refresh(credentials, transport: transport)
                Log.codex.debug("Refreshed Codex access token")
            } catch {
                // A refresh failure is not fatal on its own: the stored access token may still be
                // valid. Try the usage call anyway and let a 401 be the authority.
                Log.codex.warning("Codex token refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            let response = try await CodexUsageFetcher.fetchUsage(
                accessToken: credentials.accessToken,
                accountId: credentials.accountId,
                env: env,
                transport: transport
            )
            await gate.recordSuccess(.codex)
            return .loaded(Self.snapshot(from: response))
        } catch CodexFetchError.serverError(429, _) {
            await gate.recordRateLimit(.codex, retryAfter: nil)
            return .failed("Codex usage API rate-limited. Try again in a few minutes.")
        } catch CodexFetchError.unauthorized where !credentials.refreshToken.isEmpty {
            // The stored token was stale after all — refresh once, then retry.
            do {
                let refreshed = try await CodexTokenRefresher.refresh(credentials, transport: transport)
                let response = try await CodexUsageFetcher.fetchUsage(
                    accessToken: refreshed.accessToken,
                    accountId: refreshed.accountId,
                    env: env,
                    transport: transport
                )
                await gate.recordSuccess(.codex)
                return .loaded(Self.snapshot(from: response))
            } catch CodexFetchError.serverError(429, _) {
                await gate.recordRateLimit(.codex, retryAfter: nil)
                return .failed("Codex usage API rate-limited. Try again in a few minutes.")
            } catch {
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func snapshot(from response: CodexUsageResponse, now: Date = Date()) -> UsageSnapshot {
        let primary = response.rateLimit?.primaryWindow?.window
        let secondary = response.rateLimit?.secondaryWindow?.window
        // `primary` describes ordering, not duration. Plans with one quota can put a
        // seven-day window there, so use the reported duration to classify it.
        let primaryIsWeekly = primary?.windowSeconds.map { $0 >= 24 * 60 * 60 } == true
        let session = primaryIsWeekly ? secondary : primary
        let weekly = primaryIsWeekly ? primary : secondary

        return UsageSnapshot(
            provider: .codex,
            session: session,
            weekly: weekly,
            planLabel: response.planType.map(Self.planLabel),
            credits: response.credits.map {
                CreditsSnapshot(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
            },
            fetchedAt: now,
            // Plans without a five-hour cap still report the weekly one; that shape, and not a
            // response with no windows at all, is what "no session limit" looks like.
            sessionIsUnlimited: session == nil && weekly != nil
        )
    }

    /// `plus` -> `Plus`, `free_workspace` -> `Free Workspace`.
    public static func planLabel(_ raw: String) -> String {
        PlanLabel.humanize(raw)
    }
}
