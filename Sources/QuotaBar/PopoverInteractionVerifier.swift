#if DEBUG
import AppKit
import QuotaBarCore
import SwiftUI

/// Exercises AppKit's real menu command route and the popover's capped layout with fixtures.
@MainActor
enum PopoverInteractionVerifier {
    private static let suite = "QuotaBarPopoverInteractionVerifier"

    @MainActor
    private final class Requests {
        var quota = 0

        func fetch(_ provider: Provider) async -> ProviderState {
            self.quota += 1
            return .loaded(CardDump.loadedSnapshot(provider))
        }
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("popover interaction verification run loop stopped")
    }

    private static func verify() async -> Never {
        guard UserDefaults(suiteName: Self.suite) != nil else {
            VerifierReport.report("could not isolate preferences", label: "popover interaction verification")
            exit(2)
        }
        let defaults = EphemeralDefaults.make(Self.suite)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarPopoverInteraction-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return Self.finish("could not create fixture directory: \(error)", scratch: scratch)
        }
        func require(_ condition: Bool, _ message: String) {
            if !condition { Self.finish(message, scratch: scratch) }
        }

        let settings = SettingsStore(defaults: defaults)
        settings.refreshFrequency = .manual
        settings.menuBarProvider = .codex
        let service = CostService(pricingOverlay: PricingOverlay())
        let requests = Requests()
        var uptime: TimeInterval = 1_000
        let store = UsageStore(
            settings: settings,
            costService: service,
            clock: { uptime },
            fetchState: { provider, _ in await requests.fetch(provider) },
            fetchCost: { provider in CardDump.busyCost(provider) },
            historyStore: UsageHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            recoveryDefaults: defaults
        )
        let pricing = PricingEditorModel(
            costService: service,
            fixtures: .init(usage: [:], overlay: PricingOverlay()),
            saveOperations: .init(freeze: {}, write: { _ in }, invalidate: {})
        )
        let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
        controller.installApplicationMenu()

        guard let menu = NSApp.mainMenu,
              let commands = menu.items.first?.submenu,
              let refreshItem = commands.item(withTitle: "Refresh"),
              let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ) else {
            return Self.finish("the native Refresh key equivalent was unavailable", scratch: scratch)
        }

        commands.update()
        require(refreshItem.isEnabled, "the Refresh command started disabled")
        require(menu.performKeyEquivalent(with: key), "Cmd-R did not reach the application menu")
        require(await Self.wait(until: { requests.quota == 1 && !store.isRefreshing(.codex) }),
                "Cmd-R did not complete one fixture request")

        commands.update()
        require(!refreshItem.isEnabled, "the Refresh command ignored its cooldown validation")
        _ = menu.performKeyEquivalent(with: key)
        await Task.yield()
        require(requests.quota == 1, "Cmd-R bypassed the refresh cooldown")

        uptime = 1_061
        commands.update()
        require(refreshItem.isEnabled, "the Refresh command did not re-enable after cooldown")
        require(menu.performKeyEquivalent(with: key), "Cmd-R remained disabled after cooldown")
        require(await Self.wait(until: { requests.quota == 2 && !store.isRefreshing(.codex) }),
                "Cmd-R did not run after cooldown")

        // A dense fixture must scroll inside the content viewport while actions stay below it.
        store.debugSetDisplay(ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(.codex), cost: CardDump.busyCost(.codex)
        ), for: .codex)
        controller.debugShowPopover()
        RunLoopDrain.run(for: 0.15)
        guard let popover = controller.debugPopover,
              let hosting = popover.contentViewController as? NSHostingController<MenuPopoverView> else {
            return Self.finish("the native popover did not open", scratch: scratch)
        }
        let model = hosting.rootView.model
        model.maximumHeight = 220
        model.onSizeChanged()
        RunLoopDrain.run(for: 0.05)
        require(model.contentHeight > model.viewportHeight, "the dense card did not require scrolling")
        require(popover.contentSize.width == 280 && popover.contentSize.height <= 220,
                "the popover exceeded its capped 280 pt viewport")
        require(model.footerHeight == 85 && model.viewportHeight <= 135,
                "the action footer did not retain space below the scroll viewport")

        popover.performClose(nil)
        store.stop()
        withExtendedLifetime(controller) {}
        Self.finish(nil, scratch: scratch)
    }

    private static func wait(until ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return ready()
    }

    private static func finish(_ failure: String?, scratch: URL) -> Never {
        EphemeralDefaults.clear(Self.suite)
        try? FileManager.default.removeItem(at: scratch)
        if let failure {
            VerifierReport.report(failure, label: "popover interaction verification")
            exit(1)
        }
        print("Native Cmd-R, cooldown, and capped popover layout checks passed")
        exit(0)
    }
}
#endif
