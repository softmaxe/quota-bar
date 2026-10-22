@testable import QuotaBarApp
import QuotaBarCore
import AppKit
import Foundation

/// Proves the Refresh row narrates the cooldown instead of silently dropping clicks: it counts
/// down on its own clock while the menu stands open, refuses clicks until the wait is over, and
/// comes back by itself.
@MainActor
enum RefreshRowTests {
    private static let suite = "QuotaBarRefreshRowTests"

    static func run() async {
        await AppCheck.run("refresh row") {
            let defaults = EphemeralDefaults.make(Self.suite)
            defer { EphemeralDefaults.clear(Self.suite) }
            NSApplication.shared.setActivationPolicy(.accessory)

            // The store reads this on every claim, so moving it is the whole of "time passed".
            var now: TimeInterval = 1_000
            let settings = SettingsStore(defaults: defaults)
            let costService = CostService()
            let store = UsageStore(settings: settings, costService: costService, clock: { now }, recoveryDefaults: defaults)
            let controller = StatusItemController(
                store: store,
                settings: settings,
                pricing: PricingTableModel(costService: costService),
                openMenuClockInterval: 3_600,
                refreshRowClockInterval: 0.01
            )

            // A refresh the user cannot see the result of yet: the row must say how long the wait is.
            store.debugRecordRefresh(at: now)
            controller.debugBeginPresentation()
            controller.debugStartRefreshRowClock()
            defer {
                controller.debugStopRefreshRowClock()
                controller.debugEndPresentation()
            }
            try await Self.requireRow(controller, "Refresh", trailing: "59s", enabled: false, step: "just after a refresh")

            // The row advances on its own clock, with nothing else publishing.
            now = 1_030
            try await Self.requireRow(controller, "Refresh", trailing: "29s", enabled: false, step: "half a cooldown later")

            // A click during the cooldown is refused by the row itself, so the store is never asked.
            // The click redraws the row before it returns, so an accepted click would already show.
            controller.debugClickRefreshRow()
            try await Self.requireRow(controller, "Refresh", trailing: "29s", enabled: false, step: "after a refused click")

            // An automatic Claude 401 is different from an ordinary API cooldown: the existing row
            // is the only place where the user can explicitly authorize delegated recovery.
            var recovery = ProviderDisplay()
            recovery.error = "Claude credentials need recovery."
            recovery.canAttemptCredentialRecovery = true
            store.debugSetDisplay(recovery, for: settings.menuBarProvider)
            try await Self.requireRow(controller, "Refresh", trailing: nil, enabled: true,
                                step: "while credential recovery is available")

            store.debugSetDisplay(ProviderDisplay(), for: settings.menuBarProvider)
            try await Self.requireRow(controller, "Refresh", trailing: "29s", enabled: false,
                                step: "after credential recovery is cleared")

            // And the row comes back by itself, without the menu being reopened.
            now = 1_059
            try await Self.requireRow(controller, "Refresh", trailing: nil, enabled: true, step: "once the cooldown elapsed")
        }
    }

    private static func requireRow(
        _ controller: StatusItemController,
        _ title: String,
        trailing: String?,
        enabled: Bool,
        step: String
    ) async throws {
        // The row redraws from a timer and from store publishes, both of which land on later
        // run-loop turns, during menu tracking.
        await AppCheck.waitDuringMenuTracking(until: {
            guard let state = controller.debugRefreshRowState() else { return false }
            return state.title == title && state.trailingText == trailing && state.isEnabled == enabled
        })
        guard let state = controller.debugRefreshRowState() else {
            throw CheckFailure(description: "\(step): the menu carries no Refresh row")
        }
        try AppCheck.require(
            state.title == title && state.trailingText == trailing && state.isEnabled == enabled,
            "\(step): row read \"\(state.title)\" trailing \"\(state.trailingText ?? "")\" "
                + "(enabled: \(state.isEnabled)), expected \"\(title)\" trailing "
                + "\"\(trailing ?? "")\" (enabled: \(enabled))"
        )
    }
}
