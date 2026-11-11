@testable import QuotaBarApp
import QuotaBarCore
import AppKit
import Foundation

/// Proves an open menu advances its relative timestamp while no provider refresh is published.
@MainActor
enum RelativeTimeTests {
    private static let suite = "QuotaBarRelativeTimeTests"

    static func run() async {
        await AppCheck.run("settings relative clock pauses while hidden") {
            let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var now = base
            let clock = SettingsClock(now: { now }, interval: 0.01)
            try AppCheck.require(!clock.isRunning, "hidden settings started a clock")
            clock.setActive(true)
            now = base.addingTimeInterval(120)
            await AppCheck.waitDuringMenuTracking(until: { clock.now == now })
            try AppCheck.require(Formatters.relativeAge(since: base, now: clock.now) == "2m ago",
                                 "settings clock did not advance without a data refresh")
            clock.setActive(false)
            now = base.addingTimeInterval(240)
            try? await Task.sleep(for: .milliseconds(40))
            try AppCheck.require(!clock.isRunning && clock.now == base.addingTimeInterval(120),
                                 "hidden settings kept advancing")
            clock.setActive(true)
            try AppCheck.require(clock.now == now, "reopening did not catch up immediately")
            clock.setActive(false)
        }
        await AppCheck.run("open-menu relative time") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            NSApplication.shared.setActivationPolicy(.accessory)

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
                pricing: PricingTableModel(costService: costService),
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
            defer { controller.debugEndPresentation() }

            try AppCheck.require(
                controller.debugStatusLine() == "Updated just now",
                "initial label was \(controller.debugStatusLine() ?? "nil")"
            )

            now = base.addingTimeInterval(120)
            controller.debugStartOpenMenuClock()
            // The clock is a real timer whose tick hops to the main actor before it redraws.
            // Waiting for the label the tick produces proves the timer runs during menu tracking.
            await AppCheck.waitDuringMenuTracking(until: { controller.debugStatusLine() == "Updated 2m ago" })
            controller.debugStopOpenMenuClock()

            try AppCheck.require(
                controller.debugStatusLine() == "Updated 2m ago",
                "label after two minutes was \(controller.debugStatusLine() ?? "nil")"
            )
        }
    }
}
