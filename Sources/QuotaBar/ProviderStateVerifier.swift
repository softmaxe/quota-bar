#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// Exercises quota and local-scan state without reading credentials, logs, or the network.
@MainActor
enum ProviderStateVerifier {
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
            return await withCheckedContinuation { self.cost = $0 }
        }

        static func snapshot(at date: Date) -> CostSnapshot {
            CostSnapshot(
                provider: .codex, days: [], todayCostUSD: 0, windowCostUSD: 0,
                latestTokens: 0, windowTokens: 0, topModel: nil,
                hasUnpricedTokens: false, scannedAt: date
            )
        }
    }

    static func run() -> Never {
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("verification run loop stopped")
    }

    private static func verify() async -> Never {
        let suite = "QuotaBarProviderStateVerifier"
        let defaults = EphemeralDefaults.make(suite)
        func finish(_ message: String? = nil) -> Never {
            EphemeralDefaults.clear(suite)
            if let message {
                VerifierReport.report(message, label: "provider-state verification")
                exit(1)
            }
            print("Provider states preserve reasons, cached readings, scan progress, and retry eligibility")
            exit(0)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        var uptime: TimeInterval = 1_000
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = SettingsStore(defaults: defaults)
        let fetches = Fetches()
        let store = UsageStore(
            settings: settings,
            costService: CostService(pricingOverlay: PricingOverlay()),
            clock: { uptime },
            dateClock: { origin.addingTimeInterval(uptime - 1_000) },
            fetchState: { _, _ in await fetches.fetchQuota() },
            fetchCost: { _ in await fetches.fetchCost() },
            historyStore: UsageHistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            recoveryDefaults: defaults
        )

        store.refresh()
        guard await Self.wait(until: { fetches.quota != nil && fetches.cost != nil }) else {
            finish("initial work did not start")
        }
        guard store.isRefreshing(.codex),
              store.displays[.codex]?.localScanStatus == .scanning else {
            finish("quota and local scan did not start independently")
        }
        store.refresh()
        guard fetches.quotaCalls == 1, fetches.costCalls == 1 else {
            finish("a second request was not coalesced")
        }

        fetches.quota?.resume(returning: .signedOut("Run codex login to sign in."))
        fetches.quota = nil
        guard await Self.wait(until: { store.displays[.codex]?.isSignedOut == true }) else {
            finish("signed-out state was not applied")
        }
        guard store.displays[.codex]?.signedOutReason == "Run codex login to sign in.",
              store.displays[.codex]?.localScanStatus == .scanning else {
            finish("signed-out reason or independent scan state was lost")
        }

        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        guard await Self.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }) else {
            finish("local scan failure was not exposed")
        }
        guard store.displays[.codex]?.error == nil else {
            finish("local scan failure was mislabeled a quota failure")
        }

        store.retryLocalUsage()
        guard await Self.wait(until: { fetches.costCalls == 2 && fetches.cost != nil }) else {
            finish("local usage retry did not start")
        }
        guard fetches.quotaCalls == 1,
              store.displays[.codex]?.localScanStatus == .scanning else {
            finish("local usage retry changed quota state or skipped progress")
        }
        store.retryLocalUsage()
        guard fetches.costCalls == 2 else {
            finish("repeated local usage retry started a duplicate scan")
        }
        fetches.cost?.resume(returning: Fetches.snapshot(at: origin))
        fetches.cost = nil
        guard await Self.wait(until: {
            if case .some(.completed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }) else {
            finish("local usage retry did not report completion")
        }
        guard fetches.quotaCalls == 1,
              store.displays[.codex]?.cost == Fetches.snapshot(at: origin) else {
            finish("local usage retry changed quota or lost its result")
        }

        uptime = 1_059
        guard store.canRefresh(.codex) else { finish("local cooldown did not expire") }
        store.refresh()
        guard await Self.wait(until: { fetches.quota != nil && fetches.cost != nil }) else {
            finish("second refresh did not start")
        }
        let snapshot = UsageSnapshot(
            provider: .codex, session: nil, weekly: nil, planLabel: nil,
            credits: nil, fetchedAt: origin.addingTimeInterval(59)
        )
        fetches.quota?.resume(returning: .loaded(snapshot))
        fetches.quota = nil
        guard await Self.wait(until: { store.displays[.codex]?.snapshot == snapshot }) else {
            finish("quota success did not apply")
        }
        guard store.displays[.codex]?.failure == nil,
              store.displays[.codex]?.signedOutReason == nil else {
            finish("quota success left an old warning")
        }
        fetches.cost?.resume(returning: Fetches.snapshot(at: origin.addingTimeInterval(59)))
        fetches.cost = nil
        guard await Self.wait(until: {
            if case .some(.completed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }) else {
            finish("second local scan did not report completion")
        }
        guard store.displays[.codex]?.cost == Fetches.snapshot(at: origin.addingTimeInterval(59)) else {
            finish("local scan completion did not apply usage")
        }

        uptime = 1_118
        let deadline = origin.addingTimeInterval(118 + 300)
        store.refresh()
        guard await Self.wait(until: { fetches.quota != nil && fetches.cost != nil }) else {
            finish("rate-limit fixture did not start")
        }
        fetches.quota?.resume(returning: .rateLimited(reason: "API limited", retryAfter: deadline))
        fetches.quota = nil
        guard await Self.wait(until: { store.displays[.codex]?.retryDeadline == deadline }) else {
            finish("server retry deadline was not kept")
        }
        guard store.displays[.codex]?.snapshot == snapshot,
              store.displays[.codex]?.failure?.kind == .rateLimited,
              abs(store.cooldownRemaining(for: .codex) - 300) < 0.01,
              store.retryEligibleAt(for: .codex) == deadline,
              !store.canRefresh(.codex) else {
            finish("cached quota or effective server retry state is wrong")
        }
        store.refresh(force: true, interaction: .userInitiated)
        guard fetches.quotaCalls == 3 else {
            finish("a force request bypassed the server retry deadline")
        }
        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        guard await Self.wait(until: {
            if case .some(.failed) = store.displays[.codex]?.localScanStatus { return true }
            return false
        }) else {
            finish("rate-limit fixture's local scan did not finish")
        }

        uptime = 1_418
        guard store.canRefresh(.codex) else { finish("server deadline did not expire") }
        store.refresh()
        guard await Self.wait(until: { fetches.quota != nil && fetches.cost != nil }) else {
            finish("post-limit refresh did not start")
        }
        fetches.quota?.resume(returning: .loaded(snapshot))
        fetches.quota = nil
        guard await Self.wait(until: { store.displays[.codex]?.failure == nil }) else {
            finish("successful retry did not clear the warning")
        }
        fetches.cost?.resume(returning: nil)
        fetches.cost = nil
        store.stop()
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
