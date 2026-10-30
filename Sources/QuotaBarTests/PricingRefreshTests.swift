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
        var costCalls = 0
        var quota: CheckedContinuation<ProviderState, Never>?
        var cost: CheckedContinuation<CostSnapshot?, Never>?

        func fetchQuota() async -> ProviderState {
            self.quotaCalls += 1
            return await withCheckedContinuation { self.quota = $0 }
        }

        func fetchCost() async -> CostSnapshot? {
            self.costCalls += 1
            if self.costCalls == 1 {
                return await withCheckedContinuation { self.cost = $0 }
            }
            return Self.snapshot(cost: Double(self.costCalls))
        }

        static func snapshot(cost: Double) -> CostSnapshot {
            CostSnapshot(
                provider: .codex, days: [], todayCostUSD: cost, windowCostUSD: cost,
                latestTokens: 1, windowTokens: 1, topModel: "gpt-6-astra",
                hasUnpricedTokens: false, scannedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
    }

    static func run() async {
        await AppCheck.run("rate changes refresh costs without extra quota requests") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            NSApplication.shared.setActivationPolicy(.accessory)
            let settings = SettingsStore(defaults: defaults)
            // The fixture follows Codex; pin it rather than rely on the fresh-install default.
            settings.menuBarProvider = .codex
            let service = CostService(rateCard: RateCard())
            let fetches = Fetches()
            let store = UsageStore(
                settings: settings, costService: service,
                fetchState: { _, _ in await fetches.fetchQuota() },
                fetchCost: { _ in await fetches.fetchCost() },
                recoveryDefaults: defaults
            )
            let pricing = PricingTableModel(costService: service)
            let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
            defer {
                // Never leave a fetch suspended on a continuation once the check stops.
                fetches.quota?.resume(returning: .failed("Offline fixture"))
                fetches.cost?.resume(returning: nil)
                store.stop()
                withExtendedLifetime(controller) {}
            }
            store.refresh()
            try AppCheck.require(await AsyncWait.wait(until: { fetches.quota != nil && fetches.cost != nil }),
                                 "fixture requests did not start")
            for _ in 0..<3 { store.refreshCostsAfterPricingChange() }
            fetches.cost?.resume(returning: Fetches.snapshot(cost: 1))
            fetches.cost = nil
            try AppCheck.require(await AsyncWait.wait(until: {
                fetches.costCalls == 2 && store.displays[.codex]?.cost == Fetches.snapshot(cost: 2)
            }), "a rate change was lost while quota and cost work were in flight")
            store.refreshCostsAfterPricingChange()
            try AppCheck.require(await AsyncWait.wait(until: {
                fetches.costCalls == 3 && store.displays[.codex]?.cost == Fetches.snapshot(cost: 3)
            }), "an in-flight quota request blocked a local cost refresh")
            try AppCheck.require(fetches.quotaCalls == 1, "a rate change made an extra quota request")
            fetches.quota?.resume(returning: .failed("Offline fixture"))
            fetches.quota = nil
            await Task.yield()
        }
    }
}
