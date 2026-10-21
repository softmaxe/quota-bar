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
