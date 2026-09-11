import QuotaBarCore
import Foundation

// MARK: - Codex

do {
    let json = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": { "used_percent": 0, "reset_at": 1000, "limit_window_seconds": 18000 },
        "secondary_window": { "used_percent": 14, "reset_at": 2000, "limit_window_seconds": 604800 }
      },
      "credits": { "has_credits": false, "unlimited": false, "balance": 0 }
    }
    """
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let snapshot = CodexProvider.snapshot(from: response)

    Harness.expectEqual(snapshot.planLabel, "Plus", "codex plan label")
    Harness.expectEqual(snapshot.session?.remainingPercent, 100, "codex session remaining")
    Harness.expectEqual(snapshot.weekly?.remainingPercent, 86, "codex weekly remaining")
    Harness.expectEqual(snapshot.session?.resetsAt, Date(timeIntervalSince1970: 1000), "codex session reset")
    Harness.expect(!snapshot.sessionIsUnlimited, "codex five-hour window is a real session limit")
    Harness.expectEqual(snapshot.weekly?.windowSeconds, 604_800, "codex weekly window length")
    Harness.expectEqual(snapshot.credits?.balance, 0, "codex credit balance")
} catch {
    Harness.expect(false, "codex usage decode threw: \(error)")
}

// A malformed window must not take its sibling down with it.
do {
    let json = """
    {
      "rate_limit": {
        "primary_window": "nonsense",
        "secondary_window": { "used_percent": 40, "reset_at": 2000, "limit_window_seconds": 604800 }
      }
    }
    """
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    Harness.expect(response.rateLimit?.primaryWindow == nil, "malformed primary window should decode to nil")
    Harness.expectEqual(response.rateLimit?.secondaryWindow?.usedPercent, 40, "sibling window survives")
} catch {
    Harness.expect(false, "codex partial decode threw: \(error)")
}

// Some Pro responses expose a primary window shell without a usable percentage. It
// must not become a fully available five-hour limit when the weekly limit is valid.
do {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": null },
        "secondary_window": { "used_percent": 50, "reset_at": 2000, "limit_window_seconds": 604800 }
      }
    }
    """
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let snapshot = CodexProvider.snapshot(from: response)

    Harness.expect(snapshot.session == nil, "codex missing five-hour utilization hides the session limit")
    Harness.expect(snapshot.sessionIsUnlimited, "codex weekly-only response has no session limit")
    Harness.expectEqual(snapshot.weekly?.remainingPercent, 50, "codex weekly-only remaining")
} catch {
    Harness.expect(false, "codex weekly-only usage decode threw: \(error)")
}

// A plan with one seven-day quota may return it in the primary slot. Classify the
// window by duration so the menu bar does not present it as a five-hour session.
do {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 25, "reset_at": 2000, "limit_window_seconds": 604800 },
        "secondary_window": null
      }
    }
    """
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let snapshot = CodexProvider.snapshot(from: response)

    Harness.expect(snapshot.session == nil, "codex seven-day primary window does not become a session limit")
    Harness.expect(snapshot.sessionIsUnlimited, "codex seven-day-only plan has no session limit")
    Harness.expectEqual(snapshot.weekly?.remainingPercent, 75, "codex seven-day primary becomes weekly")
} catch {
    Harness.expect(false, "codex primary weekly usage decode threw: \(error)")
}

// If a five-hour quota returns beside a primary seven-day quota, duration-based
// classification restores both lanes even when the API does not reorder the slots.
do {
    let json = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 25, "reset_at": 2000, "limit_window_seconds": 604800 },
        "secondary_window": { "used_percent": 40, "reset_at": 1000, "limit_window_seconds": 18000 }
      }
    }
    """
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let snapshot = CodexProvider.snapshot(from: response)

    Harness.expectEqual(snapshot.session?.remainingPercent, 60, "codex restored five-hour remaining")
    Harness.expectEqual(snapshot.weekly?.remainingPercent, 75, "codex retained weekly remaining")
} catch {
    Harness.expect(false, "codex restored five-hour usage decode threw: \(error)")
}

// An empty balance is not worth a section: the popover hides it rather than showing "0 left".
Harness.expect(
    !CreditsSnapshot(hasCredits: false, unlimited: false, balance: 0).hasSpendableBalance,
    "no credits hides the section"
)
Harness.expect(
    !CreditsSnapshot(hasCredits: true, unlimited: false, balance: 0).hasSpendableBalance,
    "drained balance hides the section"
)
Harness.expect(
    !CreditsSnapshot(hasCredits: true, unlimited: false, balance: nil).hasSpendableBalance,
    "missing balance hides the section"
)
Harness.expect(
    CreditsSnapshot(hasCredits: true, unlimited: false, balance: 640).hasSpendableBalance,
    "positive balance shows the section"
)
Harness.expect(
    CreditsSnapshot(hasCredits: false, unlimited: true, balance: nil).hasSpendableBalance,
    "unlimited credits show the section"
)

Harness.expectEqual(CodexProvider.planLabel("plus"), "Plus", "plan label simple")
Harness.expectEqual(CodexProvider.planLabel("free_workspace"), "Free Workspace", "plan label underscored")

// The default chatgpt.com base already carries /backend-api, so the wham path applies.
Harness.expectEqual(
    CodexUsageFetcher.usageURL(env: ["CODEX_HOME": "/nonexistent"]).absoluteString,
    "https://chatgpt.com/backend-api/wham/usage",
    "codex usage URL"
)
Harness.expectEqual(
    CodexCredentialsStore.authFileURL(env: ["CODEX_HOME": "/tmp/codexhome"]).path,
    "/tmp/codexhome/auth.json",
    "codex auth path honours CODEX_HOME"
)

// MARK: - Claude

do {
    let json = """
    {
      "claudeAiOauth": {
        "accessToken": "token-123",
        "refreshToken": "refresh-456",
        "expiresAt": 1700000000000,
        "scopes": ["user:profile", "user:inference"],
        "subscriptionType": "pro"
      }
    }
    """
    let credentials = try ClaudeCredentialsStore.parse(data: Data(json.utf8))
    Harness.expectEqual(credentials.accessToken, "token-123", "claude access token")
    Harness.expectEqual(credentials.refreshToken, "refresh-456", "claude refresh token")
    // Claude Code stores the expiry in milliseconds.
    Harness.expectEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_700_000_000), "claude expiry")
    Harness.expectEqual(credentials.subscriptionType, "pro", "claude subscription")
} catch {
    Harness.expect(false, "claude credential parse threw: \(error)")
}

Harness.expectThrows("claude payload without claudeAiOauth") {
    _ = try ClaudeCredentialsStore.parse(data: Data(#"{"mcpOAuth": {}}"#.utf8))
}

do {
    let json = """
    {
      "five_hour": { "utilization": 29, "resets_at": "2026-08-26T20:00:00Z" },
      "seven_day": { "utilization": 3, "resets_at": "2026-09-01T20:00:00.500Z" }
    }
    """
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    let credentials = ClaudeCredentials(
        accessToken: "t",
        refreshToken: nil,
        expiresAt: nil,
        scopes: [],
        subscriptionType: "max"
    )
    let snapshot = ClaudeProvider.snapshot(from: response, credentials: credentials)

    Harness.expectEqual(snapshot.session?.remainingPercent, 71, "claude session remaining")
    Harness.expectEqual(snapshot.weekly?.remainingPercent, 97, "claude weekly remaining")
    Harness.expectEqual(snapshot.planLabel, "Max", "claude plan label")
    // Both the plain and the fractional-seconds ISO-8601 forms must parse.
    Harness.expect(snapshot.session?.resetsAt != nil, "claude session reset parsed")
    Harness.expect(snapshot.weekly?.resetsAt != nil, "claude fractional-seconds reset parsed")
} catch {
    Harness.expect(false, "claude usage decode threw: \(error)")
}

// Every Claude plan has a five-hour window, so a response missing it is missing data, not a plan
// without the limit: the card must not claim the session is unlimited.
do {
    let json = """
    { "seven_day": { "utilization": 3, "resets_at": "2026-09-01T20:00:00Z" } }
    """
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    let credentials = ClaudeCredentials(
        accessToken: "t",
        refreshToken: nil,
        expiresAt: nil,
        scopes: [],
        subscriptionType: "pro"
    )
    let snapshot = ClaudeProvider.snapshot(from: response, credentials: credentials)

    Harness.expect(snapshot.session == nil, "claude missing five-hour window stays absent")
    Harness.expect(!snapshot.sessionIsUnlimited, "claude missing five-hour window is not unlimited")
} catch {
    Harness.expect(false, "claude weekly-only usage decode threw: \(error)")
}

await CostTests.run()
await ScannerRegressionTests.run()
await AstraPricingTests.run()
await RateLimitTests.run()
await ClaudeRefreshTests.run()
await CodexRefreshTests.run()
ProviderRefreshCooldownTests.run()
RefreshRowPolicyTests.run()
MenuBarProviderPolicyTests.run()
await MainActor.run { SettingsTests.run() }
PaceTests.run()
HistoricalPaceTests.run()
PricingOverrideTests.run()

Harness.finish()
