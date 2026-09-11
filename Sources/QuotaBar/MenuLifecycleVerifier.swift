#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// Exercises the real controller without provider requests or user preferences.
@MainActor
enum MenuLifecycleVerifier {
    static func benchmark() -> Never { self.run(benchmarkOnly: true) }
    static func run() -> Never { self.run(benchmarkOnly: false) }

    private static func run(benchmarkOnly: Bool) -> Never {
        let suite = "QuotaBarMenuLifecycleVerifier"
        let defaults = EphemeralDefaults.make(suite)
        func finish(_ code: Int32) -> Never {
            defaults.removePersistentDomain(forName: suite)
            exit(code)
        }
        func require(_ condition: Bool, _ message: String) {
            if !condition {
                VerifierReport.report(message, label: "menu-lifecycle verification")
                finish(1)
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let settings = SettingsStore(defaults: defaults)
        let service = CostService(pricingOverlay: PricingOverlay())
        let store = UsageStore(settings: settings, costService: service, clock: { 1_000 })
        let started = ContinuousClock.now
        let controller = StatusItemController(
            store: store, settings: settings,
            pricing: PricingEditorModel(costService: service)
        )
        let elapsed = started.duration(to: .now)
        print(String(format: "status_item_init_ms=%.3f menu_created=%@",
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15,
            controller.debugHasMenu ? "yes" : "no"))
        if benchmarkOnly { finish(0) }
        require(!controller.debugHasMenu, "startup eagerly built the hidden menu")

        // No observers are started on the store, and both cooldowns are pinned, so even
        // opening the actual menu delegate cannot initiate a provider or cost request.
        for provider in Provider.allCases { store.debugRecordRefresh(at: 1_000, provider: provider) }
        var display = ProviderDisplay()
        display.error = "Offline fixture"
        store.debugSetDisplay(display, for: settings.menuBarProvider)
        RunLoopDrain.run()
        require(!controller.debugHasMenu, "a background update built the hidden menu")

        let menu = NSMenu()
        controller.menuWillOpen(menu)
        require(controller.debugHasMenu, "opening did not build the menu")
        require(controller.debugStatusLine() == "Refresh failed", "first open lost the latest state")
        controller.menuDidClose(menu)
        let updates = controller.debugCardUpdateCount
        display.isSignedOut = true
        store.debugSetDisplay(display, for: settings.menuBarProvider)
        RunLoopDrain.run()
        require(controller.debugCardUpdateCount == updates, "background updates laid out a closed card")
        controller.menuWillOpen(menu)
        require(controller.debugStatusLine() == "Not signed in", "reopening showed stale state")
        require(controller.debugCardUpdateCount > updates, "reopening did not update the card")

        settings.menuBarProvider = Provider.allCases.first { $0 != settings.menuBarProvider }!
        require(controller.debugStatusLine() == "No data yet", "provider switch kept the old card")
        controller.menuDidClose(menu)
        print("Menu creation is deferred; closed cards stay idle and reopen with current state")
        finish(0)
    }
}
#endif
