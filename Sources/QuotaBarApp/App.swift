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

        /// `--flag <value>...`: the `count` arguments after `flag`, when the caller passed that
        /// many. Nil for a flag that is absent or short of its arguments, which leaves the app to
        /// launch normally rather than acting on half a request.
        func values(after flag: String, count: Int) -> [String]? {
            guard let index = arguments.firstIndex(of: flag), index + count < arguments.count else {
                return nil
            }
            return Array(arguments[(index + 1)...(index + count)])
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

        if let destination = values(after: "--export-usage-report", count: 1)?.first {
            UsageReportDumps.exportLive(to: destination)
        }

        if let state = values(after: "--preview-interface", count: 1)?.first {
            InterfacePreview.run(state: state)
        }

        // `Scripts/readme_assets.sh` drives these. Each writes its frames and exits.
        let dumps: [(flag: String, run: @MainActor (String) -> Void)] = [
            ("--dump-interaction-states", CardDump.dumpInteractionStates),
            ("--dump-icons", IconDump.run),
            ("--dump-card", CardDump.run),
            ("--dump-settings", CardDump.dumpSettings),
            ("--dump-usage-report", UsageReportDumps.dumpSampleReport),
        ]
        for dump in dumps {
            if let directory = values(after: dump.flag, count: 1)?[0] {
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
