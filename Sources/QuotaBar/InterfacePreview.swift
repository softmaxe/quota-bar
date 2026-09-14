#if DEBUG
import AppKit
import QuotaBarCore

/// Opens the real status popover with disposable data for visual and keyboard inspection.
@MainActor
enum InterfacePreview {
    private static let suite = "QuotaBarInterfacePreview"
    private static var activeDelegate: PreviewDelegate?

    static func run(state: String) -> Never {
        guard ["loaded", "signed-out", "stale"].contains(state) else {
            print("Unknown interface preview state: \(state)")
            exit(2)
        }
        guard UserDefaults(suiteName: Self.suite) != nil else {
            print("Could not isolate interface preview preferences")
            exit(2)
        }
        let defaults = EphemeralDefaults.make(Self.suite)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarInterfacePreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            EphemeralDefaults.clear(Self.suite)
            print("Could not create interface preview fixtures: \(error)")
            exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PreviewDelegate(state: state, defaults: defaults, scratch: scratch)
        Self.activeDelegate = delegate
        app.delegate = delegate
        app.run()
        fatalError("interface preview run loop stopped")
    }

    @MainActor
    private final class PreviewDelegate: NSObject, NSApplicationDelegate {
        private let scratch: URL
        private let store: UsageStore
        private let controller: StatusItemController
        private let state: String

        init(state: String, defaults: UserDefaults, scratch: URL) {
            self.state = state
            self.scratch = scratch
            let settings = SettingsStore(defaults: defaults)
            settings.refreshFrequency = .manual
            settings.menuBarProvider = state == "loaded" ? .codex : .claude
            let service = CostService(pricingOverlay: PricingOverlay())
            let store = UsageStore(
                settings: settings,
                costService: service,
                fetchState: { provider, _ in
                    let snapshot = CardDump.loadedSnapshot(provider)
                    return .loaded(snapshot)
                },
                fetchCost: { provider in CardDump.busyCost(provider) },
                historyStore: UsageHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
                recoveryDefaults: defaults
            )
            let pricing = PricingEditorModel(
                costService: service,
                fixtures: .init(usage: [:], overlay: PricingOverlay()),
                saveOperations: .init(freeze: {}, write: { _ in }, invalidate: {})
            )

            for provider in Provider.allCases {
                store.debugSetDisplay(ProviderDisplay(
                    snapshot: CardDump.loadedSnapshot(provider), cost: CardDump.busyCost(provider)
                ), for: provider)
                store.debugRecordRefresh(at: ProcessInfo.processInfo.systemUptime, provider: provider)
            }
            if state == "signed-out" {
                var display = ProviderDisplay()
                display.isSignedOut = true
                display.signedOutReason = "No Claude CLI login is available for this preview."
                store.debugSetDisplay(display, for: .claude)
            } else if state == "stale" {
                var display = ProviderDisplay(
                    snapshot: CardDump.loadedSnapshot(.claude), cost: CardDump.busyCost(.claude)
                )
                let reason = "Claude usage API is temporarily unavailable."
                display.error = reason
                display.failure = ProviderFailure(
                    kind: .rateLimited,
                    reason: reason,
                    serverRetryAfter: Date().addingTimeInterval(90)
                )
                store.debugSetDisplay(display, for: .claude)
            }
            self.store = store
            self.controller = StatusItemController(store: store, settings: settings, pricing: pricing)
            super.init()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            self.controller.installApplicationMenu()
            self.store.start()
            self.controller.debugShowPopover()
            print("Interface preview: \(self.state). Use the popover's Quit action to close.")
        }

        func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
            self.controller.applicationShouldTerminate(application)
        }

        func applicationWillTerminate(_ notification: Notification) {
            self.store.stop()
            EphemeralDefaults.clear(InterfacePreview.suite)
            try? FileManager.default.removeItem(at: self.scratch)
        }
    }
}
#endif
