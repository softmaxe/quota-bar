#if DEBUG
import AppKit
import QuotaBarCore

/// Opens the real status popover with disposable data for visual and keyboard inspection.
@MainActor
enum InterfacePreview {
    private static let suite = "QuotaBarInterfacePreview"
    private static var activeDelegate: PreviewDelegate?

    static func run(state: String) -> Never {
        guard ["loaded", "signed-out", "stale", "motion"].contains(state) else {
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
            settings.menuBarProvider = state == "loaded" || state == "motion" ? .codex : .claude
            let service = CostService(rateCard: RateCard())
            let motion = state == "motion" ? MotionPreviewSession() : nil
            let store = UsageStore(
                settings: settings,
                costService: service,
                // The motion preview runs the one-minute refresh cooldown sixty times faster,
                // so working and changing values can be watched again after a second.
                clock: { ProcessInfo.processInfo.systemUptime * (motion == nil ? 1 : 60) },
                fetchState: { provider, interaction in
                    if let motion {
                        return await motion.fetchState(provider, interaction: interaction)
                    }
                    if state == "signed-out", provider == .claude {
                        return .signedOut("No Claude CLI login is available for this preview.")
                    }
                    let snapshot = CardDump.loadedSnapshot(provider)
                    return .loaded(snapshot)
                },
                fetchCost: { provider in
                    if let motion { return await motion.fetchCost(provider) }
                    return CardDump.busyCost(provider)
                },
                historyStore: UsageHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
                recoveryDefaults: defaults
            )
            let pricing = PricingTableModel(
                costService: service,
                fixtures: .init(usage: [:])
            )

            for provider in Provider.allCases where motion == nil {
                store.debugSetDisplay(ProviderDisplay(
                    snapshot: CardDump.loadedSnapshot(provider), cost: CardDump.busyCost(provider)
                ), for: provider)
                store.debugRecordRefresh(at: ProcessInfo.processInfo.systemUptime, provider: provider)
            }
            if motion != nil {
                // Codex opens with quota but no local usage, so its first scan shows the
                // placeholder. Claude opens signed out until Check sign-in is chosen.
                store.debugSetDisplay(ProviderDisplay(snapshot: CardDump.loadedSnapshot(.codex)), for: .codex)
                var claude = ProviderDisplay()
                claude.isSignedOut = true
                claude.signedOutReason = "Choose Check sign-in to sign in this preview."
                store.debugSetDisplay(claude, for: .claude)
            } else if state == "signed-out" {
                var display = ProviderDisplay(cost: CardDump.busyCost(.claude))
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

    /// Sample providers slow enough to watch the card's motion: fetches take over a second, the
    /// first local scan of each provider takes a few, and every refresh moves the quota.
    @MainActor
    private final class MotionPreviewSession {
        private var claudeSignedIn = false
        private var scannedProviders: Set<Provider> = []

        func fetchState(_ provider: Provider, interaction: ClaudeRefreshInteraction) async -> ProviderState {
            try? await Task.sleep(for: .seconds(1.5))
            if provider == .claude, !self.claudeSignedIn {
                guard interaction == .userInitiated else {
                    return .signedOut("Choose Check sign-in to sign in this preview.")
                }
                self.claudeSignedIn = true
            }
            let sample = CardDump.loadedSnapshot(provider)
            return .loaded(UsageSnapshot(
                provider: provider,
                session: sample.session.map(Self.drifted),
                weekly: sample.weekly.map(Self.drifted),
                planLabel: sample.planLabel,
                credits: sample.credits,
                fetchedAt: Date()
            ))
        }

        func fetchCost(_ provider: Provider) async -> CostSnapshot? {
            let first = self.scannedProviders.insert(provider).inserted
            try? await Task.sleep(for: .seconds(first ? 2.4 : 1.2))
            return CardDump.busyCost(provider)
        }

        private static func drifted(_ window: UsageWindow) -> UsageWindow {
            UsageWindow(
                usedPercent: min(100, max(0, window.usedPercent + Double(Int.random(in: -8...12)))),
                resetsAt: window.resetsAt,
                windowSeconds: window.windowSeconds
            )
        }
    }
}
#endif
