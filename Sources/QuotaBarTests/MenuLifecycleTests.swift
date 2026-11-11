@testable import QuotaBarApp
import QuotaBarCore
import AppKit
import Foundation

/// Exercises the real controller without provider requests or user preferences: the menu is
/// built only when first opened, and a closed card stays idle until it is shown again.
@MainActor
enum MenuLifecycleTests {
    private static let suite = "QuotaBarMenuLifecycleTests"

    static func run() async {
        await AppCheck.run("Pi local scan retry stays on Pi and preserves the menu gauge") {
            let defaults = EphemeralDefaults.make("QuotaBarPiRetryTests")
            defer { EphemeralDefaults.clear("QuotaBarPiRetryTests") }
            let settings = SettingsStore(defaults: defaults)
            settings.menuBarProvider = .codex
            settings.refreshFrequency = .manual
            let fixture = try RecordedUsageFixture(seed: false)
            let service = CostService(databaseURL: fixture.databaseURL, env: isolatedEnvironment(root: fixture.directory), rateCard: RateCard())
            var piScans = 0
            var quotaScans = 0
            let snapshot = CostSnapshot(tab: .pi, days: [], todayCostUSD: 0, windowCostUSD: 0,
                                        latestTokens: 0, windowTokens: 0, topModel: nil,
                                        hasUnpricedTokens: false, scannedAt: Date())
            let store = UsageStore(
                settings: settings, costService: service, clock: { 1_000 },
                fetchState: { _, _ in .failed("Offline fixture") },
                fetchCost: { _ in quotaScans += 1; return nil },
                fetchPiCost: { piScans += 1; return snapshot }, updateThirdPartyRates: { false }, recoveryDefaults: defaults
            )
            defer { store.stop() }
            for provider in Provider.allCases { store.debugRecordRefresh(at: 1_000, provider: provider) }
            let controller = StatusItemController(store: store, settings: settings, pricing: PricingTableModel(costService: service))
            controller.debugSelectTab(.pi)
            try AppCheck.require(await AsyncWait.wait(until: { piScans == 1 && !store.isScanningPi }), "initial Pi scan did not complete")
            var failed = ProviderDisplay(cost: snapshot)
            failed.localScanStatus = .failed("Unreadable session fixture")
            store.debugSetPiDisplay(failed)
            controller.debugBeginPresentation()
            defer { controller.debugEndPresentation() }
            try AppCheck.require(await AsyncWait.wait(until: { !store.isScanningPi }), "reopening Pi scan did not complete")
            store.debugSetPiDisplay(failed)
            RunLoopDrain.run()
            let beforeRetry = piScans
            controller.debugRetryLocalUsage()
            try AppCheck.require(await AsyncWait.wait(until: { piScans == beforeRetry + 1 && !store.isScanningPi }),
                                 "Retry local scan did not rescan Pi")
            try AppCheck.require(quotaScans == 0 && settings.menuBarProvider == .codex && controller.debugSelectedTab == .pi,
                                 "Pi retry scanned a quota provider or changed the gauge")
        }
        await AppCheck.run("menu creation is deferred and closed cards stay idle") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            NSApplication.shared.setActivationPolicy(.accessory)
            let settings = SettingsStore(defaults: defaults)
            let service = CostService(rateCard: RateCard())
            let store = UsageStore(settings: settings, costService: service, clock: { 1_000 }, recoveryDefaults: defaults)
            let controller = StatusItemController(
                store: store, settings: settings,
                pricing: PricingTableModel(costService: service),
                useSystemStatusItemSession: true,
                reduceMotion: { false }
            )
            try AppCheck.require(!controller.debugHasMenu, "startup eagerly built the hidden menu")

            // No observers are started on the store, and both cooldowns are pinned, so even
            // opening the actual menu delegate cannot initiate a provider or cost request.
            for provider in Provider.allCases { store.debugRecordRefresh(at: 1_000, provider: provider) }
            var display = ProviderDisplay()
            display.error = "Offline fixture"
            store.debugSetDisplay(display, for: settings.menuBarProvider)
            RunLoopDrain.run()
            try AppCheck.require(!controller.debugHasMenu, "a background update built the hidden menu")

            controller.debugBeginPresentation()
            try AppCheck.require(controller.debugHasMenu, "opening did not build the menu")
            try AppCheck.require(controller.debugStatusLine() == "Refresh failed", "first open lost the latest state")
            controller.debugEndPresentation()
            let updates = controller.debugCardUpdateCount
            display.isSignedOut = true
            store.debugSetDisplay(display, for: settings.menuBarProvider)
            RunLoopDrain.run()
            try AppCheck.require(controller.debugCardUpdateCount == updates, "background updates laid out a closed card")
            controller.debugBeginPresentation()
            try AppCheck.require(controller.debugStatusLine() == "Not signed in", "reopening showed stale state")
            try AppCheck.require(controller.debugCardUpdateCount > updates, "reopening did not update the card")

            settings.menuBarProvider = Provider.allCases.first { $0 != settings.menuBarProvider }!
            try AppCheck.require(controller.debugStatusLine() == "No data yet", "provider switch kept the old card")
            controller.debugEndPresentation()
        }
    }
}
