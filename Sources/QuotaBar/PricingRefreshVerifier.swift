#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// A saved price must refresh local costs even while quota or a prior scan is in flight.
@MainActor
enum PricingRefreshVerifier {
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

    static func run() -> Never {
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
    }

    private static func verify() async -> Never {
        let suite = "QuotaBarPricingRefreshVerifier"
        let defaults = EphemeralDefaults.make(suite)
        func finish(_ message: String? = nil) -> Never {
            defaults.removePersistentDomain(forName: suite)
            if let message {
                VerifierReport.report(message, label: "pricing-refresh verification")
                exit(1)
            }
            print("Pricing saves refresh costs after in-flight work without extra quota requests")
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let settings = SettingsStore(defaults: defaults)
        let service = CostService(pricingOverlay: PricingOverlay())
        let fetches = Fetches()
        let store = UsageStore(
            settings: settings, costService: service,
            fetchState: { _, _ in await fetches.fetchQuota() },
            fetchCost: { _ in await fetches.fetchCost() }
        )
        let pricing = PricingEditorModel(costService: service)
        let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
        store.refresh()
        guard await Self.wait(until: { fetches.quota != nil && fetches.cost != nil }) else {
            finish("fixture requests did not start")
        }
        // Exercise the same callback installed for a successful PricingEditorModel.save().
        for _ in 0..<3 { pricing.onSaved?() }
        fetches.cost?.resume(returning: Fetches.snapshot(cost: 1))
        fetches.cost = nil
        guard await Self.wait(until: {
            fetches.costCalls == 2 && store.displays[.codex]?.cost == Fetches.snapshot(cost: 2)
        }) else {
            finish("a pricing save was lost while quota and cost work were in flight")
        }
        pricing.onSaved?()
        guard await Self.wait(until: {
            fetches.costCalls == 3 && store.displays[.codex]?.cost == Fetches.snapshot(cost: 3)
        }) else {
            finish("an in-flight quota request blocked a local cost refresh")
        }
        guard fetches.quotaCalls == 1 else { finish("saving prices made an extra quota request") }
        fetches.quota?.resume(returning: .failed("Offline fixture"))
        fetches.quota = nil
        await Task.yield()
        store.stop()
        withExtendedLifetime(controller) {}
        finish()
    }

    private static func wait(until ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return ready()
    }
}
#endif
