@testable import QuotaBarApp
import AppKit
import QuotaBarCore

/// Exercises AppKit's native Cmd-R route and refresh cooldown with fixtures.
@MainActor
enum MenuCommandTests {
    private static let suite = "QuotaBarMenuCommandTests"

    @MainActor
    private final class Requests {
        var quota = 0

        func fetch(_ provider: Provider) async -> ProviderState {
            self.quota += 1
            return .loaded(CardDump.loadedSnapshot(provider))
        }
    }

    static func run() async {
        await AppCheck.run("native Cmd-R routing and refresh cooldown") {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let defaults = EphemeralDefaults.make(Self.suite)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuotaBarMenuCommand-\(UUID().uuidString)", isDirectory: true)
            defer {
                EphemeralDefaults.clear(Self.suite)
                try? FileManager.default.removeItem(at: scratch)
            }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

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
            defer { store.stop() }
            let pricing = PricingTableModel(costService: service, fixtures: .init(usage: [:]))
            let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
            controller.installApplicationMenu()
            defer { withExtendedLifetime(controller) {} }

            guard let menu = NSApp.mainMenu,
                  let commands = menu.items.first?.submenu,
                  let refreshItem = commands.item(withTitle: "Refresh"),
                  let key = NSEvent.keyEvent(
                      with: .keyDown, location: .zero, modifierFlags: .command,
                      timestamp: 0, windowNumber: 0, context: nil,
                      characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
                  ) else {
                throw CheckFailure(description: "the native Refresh key equivalent was unavailable")
            }

            commands.update()
            try AppCheck.require(refreshItem.isEnabled, "the Refresh command started disabled")
            try AppCheck.require(menu.performKeyEquivalent(with: key), "Cmd-R did not reach the application menu")
            try AppCheck.require(await AsyncWait.wait(until: { requests.quota == 1 && !store.isRefreshing(.codex) }),
                                 "Cmd-R did not complete one fixture request")

            commands.update()
            try AppCheck.require(!refreshItem.isEnabled, "the Refresh command ignored its cooldown validation")
            _ = menu.performKeyEquivalent(with: key)
            await Task.yield()
            try AppCheck.require(requests.quota == 1, "Cmd-R bypassed the refresh cooldown")

            uptime = 1_061
            commands.update()
            try AppCheck.require(refreshItem.isEnabled, "the Refresh command did not re-enable after cooldown")
            try AppCheck.require(menu.performKeyEquivalent(with: key), "Cmd-R remained disabled after cooldown")
            try AppCheck.require(await AsyncWait.wait(until: { requests.quota == 2 && !store.isRefreshing(.codex) }),
                                 "Cmd-R did not run after cooldown")
        }
    }
}
