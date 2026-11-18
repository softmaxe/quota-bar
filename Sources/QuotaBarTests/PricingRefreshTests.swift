@testable import QuotaBarApp
import QuotaBarCore
import AppKit
import Foundation

/// New rates must refresh local costs even while quota or a prior scan is in flight. Updated
/// models.dev rates and the models.dev setting both reprice through this path.
@MainActor
enum PricingRefreshTests {
    private static let suite = "QuotaBarPricingRefreshTests"

    /// Main-actor isolated because the checks read and clear these fields while a fetch writes
    /// them. A nonisolated async method runs off the main actor and would race them.
    @MainActor
    private final class Fetches {
        var quotaCalls = 0
        var costCalls: [Provider: Int] = [:]
        var quota: CheckedContinuation<ProviderState, Never>?
        var costs: [Provider: CheckedContinuation<CostSnapshot?, Never>] = [:]

        func fetchQuota() async -> ProviderState {
            self.quotaCalls += 1
            return await withCheckedContinuation { self.quota = $0 }
        }

        func fetchCost(_ provider: Provider) async -> CostSnapshot? {
            self.costCalls[provider, default: 0] += 1
            let count = self.costCalls[provider]!
            if count == 1 {
                return await withCheckedContinuation { self.costs[provider] = $0 }
            }
            return Self.snapshot(provider: provider, cost: Double(count))
        }

        static func snapshot(provider: Provider, cost: Double) -> CostSnapshot {
            CostSnapshot(
                tab: UsageTab(provider: provider), days: [], todayCostUSD: cost, windowCostUSD: cost,
                latestTokens: 1, windowTokens: 1, topModel: "gpt-6-astra",
                hasUnpricedTokens: false, scannedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
    }

    static func run() async {
        await Self.stoppingDiscardsQueuedPiScans()
        await AppCheck.run("rate changes refresh costs without extra quota requests") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            NSApplication.shared.setActivationPolicy(.accessory)
            let settings = SettingsStore(defaults: defaults)
            // The fixture follows Codex; pin it rather than rely on the fresh-install default.
            settings.menuBarProvider = .codex
            settings.refreshFrequency = .manual
            let service = CostService(rateCard: RateCard())
            let fetches = Fetches()
            let store = UsageStore(
                settings: settings, costService: service,
                fetchState: { _, _ in await fetches.fetchQuota() },
                fetchCost: { await fetches.fetchCost($0) },
                updateThirdPartyRates: { false },
                recoveryDefaults: defaults
            )
            let pricing = PricingTableModel(costService: service)
            let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
            defer {
                // Never leave a fetch suspended on a continuation once the check stops.
                fetches.quota?.resume(returning: .failed("Offline fixture"))
                for cost in fetches.costs.values { cost.resume(returning: nil) }
                store.stop()
                withExtendedLifetime(controller) {}
            }
            store.refresh()
            store.refreshAllLocalUsage()
            try AppCheck.require(await AsyncWait.wait(until: {
                fetches.quota != nil && Provider.allCases.allSatisfy { fetches.costs[$0] != nil }
            }),
                                 "fixture requests did not start")
            for _ in 0..<3 { store.refreshCostsAfterPricingChange() }
            for (provider, cost) in fetches.costs {
                cost.resume(returning: Fetches.snapshot(provider: provider, cost: 1))
            }
            fetches.costs = [:]
            try AppCheck.require(await AsyncWait.wait(until: {
                Provider.allCases.allSatisfy {
                    fetches.costCalls[$0] == 2 && store.displays[$0]?.cost == Fetches.snapshot(provider: $0, cost: 2)
                }
            }), "a rate change was lost while quota and cost work were in flight")
            store.refreshCostsAfterPricingChange()
            try AppCheck.require(await AsyncWait.wait(until: {
                Provider.allCases.allSatisfy {
                    fetches.costCalls[$0] == 3 && store.displays[$0]?.cost == Fetches.snapshot(provider: $0, cost: 3)
                }
            }), "an in-flight quota request blocked a local cost refresh")
            try AppCheck.require(fetches.quotaCalls == 1, "a rate change made an extra quota request")
            fetches.quota?.resume(returning: .failed("Offline fixture"))
            fetches.quota = nil
            await Task.yield()
        }
    }

    private static func stoppingDiscardsQueuedPiScans() async {
        await AppCheck.run("stopping cancels the current and queued Pi scans") {
            let suite = "QuotaBarPiScanCancellationTests.\(UUID().uuidString)"
            let defaults = EphemeralDefaults.make(suite)
            defer { EphemeralDefaults.clear(suite) }
            var calls = 0
            var oldScan: CheckedContinuation<Void, Never>?
            var wasCancelled: Bool?
            let replacement = CostSnapshot(
                tab: .pi, days: [], todayCostUSD: 0, windowCostUSD: 0, latestTokens: 0, windowTokens: 0,
                topModel: nil, hasUnpricedTokens: false, scannedAt: Date()
            )
            let store = UsageStore(
                settings: SettingsStore(defaults: defaults), costService: CostService(rateCard: RateCard()),
                fetchPiCost: {
                    calls += 1
                    if calls == 1 {
                        await withCheckedContinuation { oldScan = $0 }
                        wasCancelled = Task.isCancelled
                        return nil
                    }
                    return replacement
                },
                updateThirdPartyRates: { false }, recoveryDefaults: defaults
            )
            defer {
                oldScan?.resume()
                store.stop()
            }
            store.refreshPiUsage()
            try AppCheck.require(await AsyncWait.wait { oldScan != nil }, "the first Pi scan did not start")
            store.refreshPiUsage(repeatingRunningScan: true)
            store.stop()
            try AppCheck.require(!store.isScanningPi, "stopping left the old Pi scan registered")

            store.refreshPiUsage()
            try AppCheck.require(await AsyncWait.wait { !store.isScanningPi && store.finishedLocalScans == 1 },
                                 "the replacement scan could not finish while the old scan was suspended")
            oldScan?.resume()
            oldScan = nil
            try AppCheck.require(await AsyncWait.wait { wasCancelled != nil }, "the old scan did not return")
            try AppCheck.require(wasCancelled == true && calls == 2 && store.finishedLocalScans == 1
                                 && store.piDisplay.cost == replacement,
                                 "stopped work was published or started another Pi scan")
        }
    }
}
