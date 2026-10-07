#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// Proves an open menu advances its relative timestamp while no provider refresh is published.
@MainActor
enum RelativeTimeVerifier {
    /// Fixed, not PID-stamped, for the reason spelled out in `finish`.
    private static let suite = "QuotaBarRelativeTimeVerifier"
    /// Held so the exit path can reach the domain this run wrote to.
    private static var defaults: UserDefaults?

    static func run() -> Never {
        let defaults = EphemeralDefaults.make(Self.suite)
        Self.defaults = defaults

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var now = base
        let settings = SettingsStore(defaults: defaults)
        // The fixture follows Codex; pin it rather than rely on the fresh-install default.
        settings.menuBarProvider = .codex
        let costService = CostService()
        let store = UsageStore(settings: settings, costService: costService, recoveryDefaults: defaults)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            pricing: PricingEditorModel(costService: costService),
            now: { now },
            openMenuClockInterval: 0.01
        )

        var display = ProviderDisplay()
        display.snapshot = UsageSnapshot(
            provider: .codex,
            session: nil,
            weekly: nil,
            planLabel: "Plus",
            credits: nil,
            fetchedAt: base
        )
        store.debugSetDisplay(display, for: .codex)
        store.debugRecordRefresh(at: ProcessInfo.processInfo.systemUptime)
        controller.debugBeginPresentation()

        Self.require(
            controller.debugStatusLine() == "Updated just now",
            "initial label was \(controller.debugStatusLine() ?? "nil")"
        )

        now = base.addingTimeInterval(120)
        controller.debugStartOpenMenuClock()
        // The clock is a real timer whose tick hops to the main actor before it redraws. Waiting a
        // fixed slice of wall time made the check fail on a loaded runner that had not reached the
        // first fire yet; waiting for the label the tick produces still proves the timer runs
        // during menu tracking.
        RunLoopDrain.run(until: { controller.debugStatusLine() == "Updated 2m ago" }, mode: .eventTracking)
        controller.debugStopOpenMenuClock()

        Self.require(
            controller.debugStatusLine() == "Updated 2m ago",
            "label after two minutes was \(controller.debugStatusLine() ?? "nil")"
        )

        print("Open-menu relative time advanced without a provider refresh")
        Self.finish(0)
    }

    /// The only way out, so the throwaway domain is dropped on the failing paths too. `defer`
    /// cannot do this job: `exit()` terminates the process without unwinding the stack.
    private static func finish(_ code: Int32) -> Never {
        EphemeralDefaults.clear(Self.suite)
        exit(code)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            VerifierReport.report(message, label: "relative-time verification")
            Self.finish(1)
        }
    }
}
#endif
