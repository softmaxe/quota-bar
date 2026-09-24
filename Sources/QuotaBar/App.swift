import QuotaBarCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let costService = CostService()
    private lazy var store = UsageStore(settings: self.settings, costService: self.costService)
    private lazy var pricing = PricingEditorModel(costService: self.costService)
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_: Notification) {
        self.controller = StatusItemController(
            store: self.store,
            settings: self.settings,
            pricing: self.pricing
        )
        self.controller?.installApplicationMenu()
        self.store.start()
        // Pricing no longer reads the models.dev catalog that 1.0.x cached.
        AppSupport.removeLegacyCatalogCache()
        if CommandLine.arguments.contains("--show-export-settings") {
            self.controller?.showExportSettings()
        }
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

@main
enum QuotaBarApp {
    @MainActor
    static func main() {
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

        // The assertion suite and the README asset dumps are launch flags rather than separate
        // executables, so none of this exists in a release build. Each entry owns the process
        // once its flag is present: the first match wins, and the order here is the order the
        // flags are checked in.
        let verifiers: [(flag: String, run: @MainActor () -> Never)] = [
            ("--verify-menu-command", MenuCommandVerifier.run),
            ("--verify-provider-state", ProviderStateVerifier.run),
            ("--verify-pricing-validation", PricingValidationVerifier.run),
            ("--verify-menu-lifecycle", MenuLifecycleVerifier.run),
            ("--verify-menu-interaction", MenuLifecycleVerifier.verifyInteraction),
            ("--verify-pricing-refresh", PricingRefreshVerifier.run),
            ("--benchmark-menu-startup", MenuLifecycleVerifier.benchmark),
            ("--verify-cost-chart-highlighting", CostChartHighlightVerifier.run),
            ("--verify-quota-recovery", QuotaRecoveryVerifier.run),
            ("--verify-relative-time", RelativeTimeVerifier.run),
            ("--verify-quota-reset-label", QuotaResetLabelVerifier.run),
            ("--verify-refresh-row", RefreshRowVerifier.run),
            ("--verify-pricing-sort", PricingSortVerifier.run),
            ("--verify-pricing-model-filter", PricingModelFilterVerifier.run),
            ("--verify-report-export", ExportReportVerifier.run),
        ]
        if let entry = verifiers.first(where: { arguments.contains($0.flag) }) {
            entry.run()
        }

        if let destination = values(after: "--export-usage-report", count: 1)?.first {
            ExportReportVerifier.exportLive(to: destination)
        }

        if let state = values(after: "--preview-interface", count: 1)?.first
            ?? (Bundle.main.object(forInfoDictionaryKey: "QuotaBarPreviewState") as? String) {
            InterfacePreview.run(state: state)
        }

        // `Scripts/readme_assets.sh` drives these. Each writes its frames and exits.
        let dumps: [(flag: String, run: @MainActor (String) -> Void)] = [
            ("--dump-interaction-states", CardDump.dumpInteractionStates),
            ("--dump-icons", IconDump.run),
            ("--dump-card", CardDump.run),
            ("--dump-settings", CardDump.dumpSettings),
            ("--dump-export-settings", ExportReportVerifier.dump),
            ("--dump-usage-report", ExportReportVerifier.dumpSampleReport),
            ("--dump-tab-switch", MotionFilmStrip.dumpTabSwitch),
            ("--dump-disclosure", MotionFilmStrip.dumpDisclosure),
            ("--dump-chart-motion", MotionFilmStrip.dumpChartMotion),
            ("--dump-label-toggle", MotionFilmStrip.dumpLabelToggle),
            ("--dump-chart-hover", CardDump.dumpChartHover),
            ("--dump-reset-toggle", CardDump.dumpResetToggle),
        ]
        for dump in dumps {
            if let directory = values(after: dump.flag, count: 1)?[0] {
                dump.run(directory)
                return
            }
        }

        // The same, for the dumps that render one named provider's card.
        let providerDumps: [(flag: String, run: @MainActor (String, Provider) -> Void)] = [
            ("--dump-card-celebration", { CelebrationDump.dumpCardFrames(directory: $0, provider: $1) }),
            ("--dump-breakdown-toggle", { CardDump.dumpBreakdownToggle(directory: $0, provider: $1) }),
        ]
        for dump in providerDumps {
            if let pair = values(after: dump.flag, count: 2) {
                dump.run(pair[0], Provider(rawValue: pair[1]) ?? .claude)
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
