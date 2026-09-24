#if DEBUG
import AppKit
import QuotaBarCore

/// Exercises AppKit's native Cmd-R route and refresh cooldown with fixtures.
@MainActor
enum MenuCommandVerifier {
    private static let suite = "QuotaBarMenuCommandVerifier"

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
        fatalError("menu command verification run loop stopped")
    }

    private static func verify() async -> Never {
        guard UserDefaults(suiteName: Self.suite) != nil else {
            VerifierReport.report("could not isolate preferences", label: "menu command verification")
            exit(2)
        }
        let defaults = EphemeralDefaults.make(Self.suite)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarMenuCommand-\(UUID().uuidString)", isDirectory: true)
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
        let service = CostService(rateCard: RateCard())
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
            fixtures: .init(usage: [:]),
            saveOperations: .init(write: { _ in }, invalidate: {})
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
            VerifierReport.report(failure, label: "menu command verification")
            exit(1)
        }
        print("Native Cmd-R routing and refresh cooldown checks passed")
        exit(0)
    }
}
#endif
