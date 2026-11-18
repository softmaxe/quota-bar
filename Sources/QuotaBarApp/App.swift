import QuotaBarCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let costService = CostService(modelsDev: .live)
    private lazy var store = UsageStore(settings: self.settings, costService: self.costService)
    private lazy var pricing = PricingTableModel(costService: self.costService)
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_: Notification) {
        self.controller = StatusItemController(
            store: self.store,
            settings: self.settings,
            pricing: self.pricing
        )
        self.controller?.installApplicationMenu()
        self.store.start()
        // Pricing no longer reads the catalog cache or the user overrides earlier versions kept.
        AppSupport.removeLegacyCatalogCache()
        AppSupport.removeLegacyOverrideFile()
        Log.ui.info("QuotaBar launched")
        print("QuotaBar launched — use the Quit menu item or Ctrl-C to stop.")
    }

    func applicationWillTerminate(_: Notification) {
        self.store.stop()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        self.controller?.applicationShouldTerminate(application) ?? .terminateNow
    }
}

/// Launches the menu bar app. The `QuotaBar` executable is only this call.
public enum QuotaBarLaunch {
    @MainActor
    public static func main() {
#if DEBUG
        let arguments = CommandLine.arguments

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            return arguments.dropFirst(index + 1).first
        }

        // Manual checks that need the real menu bar, and the README asset dumps, are launch
        // flags rather than separate executables, so none of this exists in a release build.
        // The assertion suite runs in `QuotaBarTests`. Each entry owns the process once its flag
        // is present: the first match wins.
        let checks: [(flag: String, run: @MainActor () -> Never)] = [
            ("--verify-menu-interaction", MenuLifecycleVerifier.verifyInteraction),
            ("--benchmark-menu-startup", MenuLifecycleVerifier.benchmark),
        ]
        if let entry = checks.first(where: { arguments.contains($0.flag) }) {
            entry.run()
        }

        if arguments.contains("--preview-usage-window") {
            UsageReportDumps.previewLiveWindow()
        }

        if let state = value(after: "--preview-interface") {
            InterfacePreview.run(state: state)
        }

        // Documentation and development captures each accept one output directory.
        let dumps: [(flag: String, run: @MainActor (String) -> Void)] = [
            ("--dump-interaction-states", CardDump.dumpInteractionStates),
            ("--dump-icons", IconDump.run),
            ("--dump-card", CardDump.run),
            ("--dump-settings", CardDump.dumpSettings),
            ("--dump-usage-report", UsageReportDumps.dumpSampleReport),
            ("--dump-usage-window", UsageReportDumps.dumpUsageWindow),
        ]
        for dump in dumps {
            if let directory = value(after: dump.flag) {
                dump.run(directory)
                return
            }
        }
#endif

        let app = NSApplication.shared
        // Menu bar only: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
