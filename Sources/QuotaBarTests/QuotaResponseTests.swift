@testable import QuotaBarApp
import Foundation
import QuotaBarCore

/// A decodable response still needs a quota window or meaningful credits before replacing a reading.
@MainActor
enum QuotaResponseTests {
    static func run() async {
        for shell in [#"{}"#, #"{"utilization":null}"#, #"{"utilization":"bad"}"#] {
            do {
                let json = #"{"five_hour":\#(shell),"seven_day":{"utilization":25}}"#
                let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
                let snapshot = ClaudeProvider.snapshot(from: response, credentials: Self.credentials)
                Harness.expect(snapshot.session == nil, "Claude utilization shell stays absent: \(shell)")
                Harness.expectEqual(snapshot.weekly?.remainingPercent, 75, "Claude's valid sibling survives")
                Harness.expect(!snapshot.sessionIsUnlimited, "a missing Claude session does not imply no limit")
            } catch {
                Harness.expect(false, "partial Claude response threw: \(error)")
            }
        }

        for provider in Provider.allCases {
            let empty = provider == .claude
                ? ["{}", #"{"five_hour":{},"seven_day":null}"#]
                : ["{}", #"{"plan_type":"pro","rate_limit":{}}"#, #"{"credits":{}}"#,
                   #"{"credits":{"balance":"bad","has_credits":"bad"}}"#]
            for json in empty {
                if case .failed = await Self.fetch(provider, json: json) {
                    Harness.expect(true, "empty \(provider) response fails")
                } else {
                    Harness.expect(false, "empty \(provider) response must fail: \(json)")
                }
            }
            await Self.lastReadingSurvives(provider)
        }

        let valid: [(Provider, String)] = [
            (.claude, #"{"five_hour":{"utilization":0},"seven_day":"bad"}"#),
            (.claude, #"{"five_hour":{},"seven_day":{"utilization":25}}"#),
            (.codex, #"{"rate_limit":{"primary_window":{"used_percent":0},"secondary_window":"bad"}}"#),
            (.codex, #"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":604800}}}"#),
            (.codex, #"{"credits":{"has_credits":true,"balance":"12.50"}}"#),
            (.codex, #"{"credits":{"unlimited":true}}"#),
            (.codex, #"{"credits":{"has_credits":false,"balance":0}}"#),
        ]
        for (provider, json) in valid {
            if case .loaded = await Self.fetch(provider, json: json) {
                Harness.expect(true, "usable \(provider) response succeeds")
            } else {
                Harness.expect(false, "usable \(provider) response rejected: \(json)")
            }
        }
    }

    nonisolated private static let credentials = ClaudeCredentials(accessToken: "fixture", expiresAt: nil, subscriptionType: "pro")

    private static func fetch(_ provider: Provider, json: String) async -> ProviderState {
        let transport = QuotaResponseTransport(json: json)
        switch provider {
        case .claude:
            return await ClaudeProvider.fetch(
                transport: transport, gate: UsageRateLimitGate(), credentialLoader: { Self.credentials }
            )
        case .codex:
            return await CodexProvider.fetch(
                env: ["CODEX_HOME": "/nonexistent"], transport: transport, gate: UsageRateLimitGate(),
                credentialLoader: {
                    CodexCredentials(accessToken: "fixture", refreshToken: "fixture-refresh", accountId: nil, lastRefresh: nil)
                }
            )
        }
    }

    private static func lastReadingSurvives(_ provider: Provider) async {
        await AppCheck.run("empty \(provider) response preserves the reading and its age") {
            let suite = "QuotaBarEmptyResponseTests-\(provider.rawValue)"
            let defaults = EphemeralDefaults.make(suite)
            defer { EphemeralDefaults.clear(suite) }
            let settings = SettingsStore(defaults: defaults)
            settings.menuBarProvider = provider
            var uptime: TimeInterval = 1_000
            var json = provider == .claude
                ? #"{"five_hour":{"utilization":30}}"#
                : #"{"rate_limit":{"primary_window":{"used_percent":30}}}"#
            let store = UsageStore(
                settings: settings, costService: CostService(rateCard: RateCard()), clock: { uptime },
                fetchState: { provider, _ in await Self.fetch(provider, json: json) }, fetchCost: { _ in nil },
                updateThirdPartyRates: { false },
                historyStore: UsageHistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")), recoveryDefaults: defaults
            )
            store.refresh()
            try AppCheck.require(await AsyncWait.wait(until: { store.displays[provider]?.snapshot != nil }), "first reading did not load")
            let previous = store.displays[provider]?.snapshot
            json = "{}"
            uptime += 60
            store.refresh()
            try AppCheck.require(await AsyncWait.wait(until: { !store.isRefreshing(provider) }), "empty response did not finish")
            try AppCheck.require(store.displays[provider]?.snapshot == previous, "empty response replaced the reading or fetchedAt")
            try AppCheck.require(store.displays[provider]?.error != nil, "empty response did not expose a failure")
        }
    }
}

private struct QuotaResponseTransport: HTTPTransport {
    let json: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(self.json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
