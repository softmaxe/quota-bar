#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// Proves the Refresh row narrates the cooldown instead of silently dropping clicks: it counts
/// down on its own clock while the menu stands open, refuses clicks until the wait is over, and
/// comes back by itself.
@MainActor
enum RefreshRowVerifier {
    /// Fixed, not PID-stamped, for the reason spelled out in `finish`.
    private static let suite = "QuotaBarRefreshRowVerifier"
    /// Held so the exit path can reach the domain this run wrote to.
    private static var defaults: UserDefaults?

    static func run() -> Never {
        let defaults = EphemeralDefaults.make(Self.suite)
        Self.defaults = defaults

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // The store reads this on every claim, so moving it is the whole of "time passed".
        var now: TimeInterval = 1_000
        let settings = SettingsStore(defaults: defaults)
        let costService = CostService()
        let store = UsageStore(settings: settings, costService: costService, clock: { now })
        let controller = StatusItemController(
            store: store,
            settings: settings,
            pricing: PricingEditorModel(costService: costService),
            openMenuClockInterval: 3_600,
            refreshRowClockInterval: 0.01
        )

        // A refresh the user cannot see the result of yet: the row must say how long the wait is.
        store.debugRecordRefresh(at: now)
        controller.menuWillOpen(NSMenu())
        controller.debugStartRefreshRowClock()
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(controller, "Refresh", trailing: "59s", enabled: false, step: "just after a refresh")

        // The row advances on its own clock, with nothing else publishing.
        now = 1_030
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(controller, "Refresh", trailing: "29s", enabled: false, step: "half a cooldown later")

        // A click during the cooldown is refused by the row itself, so the store is never asked.
        controller.debugClickRefreshRow()
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(controller, "Refresh", trailing: "29s", enabled: false, step: "after a refused click")

        // An automatic Claude 401 is different from an ordinary API cooldown: the existing row
        // is the only place where the user can explicitly authorize delegated recovery.
        var recovery = ProviderDisplay()
        recovery.error = "Claude credentials need recovery."
        recovery.canAttemptCredentialRecovery = true
        store.debugSetDisplay(recovery, for: settings.menuBarProvider)
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(
            controller,
            "Refresh",
            trailing: nil,
            enabled: true,
            step: "while credential recovery is available"
        )

        store.debugSetDisplay(ProviderDisplay(), for: settings.menuBarProvider)
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(
            controller,
            "Refresh",
            trailing: "29s",
            enabled: false,
            step: "after credential recovery is cleared"
        )

        // And the row comes back by itself, without the menu being reopened.
        now = 1_059
        RunLoopDrain.run(mode: .eventTracking)
        Self.requireRow(controller, "Refresh", trailing: nil, enabled: true, step: "once the cooldown elapsed")

        controller.debugStopRefreshRowClock()
        Self.requireDisabledRowSwallowsClicks()

        print("Refresh row counted the cooldown down, refused clicks, and re-enabled itself")
        Self.finish(0)
    }

    /// The row's own half of the contract: `isEnabled` has to gate the handler, not just the
    /// colour it draws in.
    private static func requireDisabledRowSwallowsClicks() {
        var clicks = 0
        let row = MenuActionRowView(width: 280, title: "Refresh", icon: nil, handler: { clicks += 1 })
        let click = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        guard let click else { Self.fail("could not synthesize a click") }

        row.isEnabled = false
        row.mouseUp(with: click)
        Self.require(clicks == 0, "a disabled row ran its handler")

        row.isEnabled = true
        row.mouseUp(with: click)
        Self.require(clicks == 1, "an enabled row did not run its handler")
    }

    private static func requireRow(
        _ controller: StatusItemController,
        _ title: String,
        trailing: String?,
        enabled: Bool,
        step: String
    ) {
        guard let state = controller.debugRefreshRowState() else {
            Self.fail("\(step): the menu carries no Refresh row")
        }
        let actualTrailing = state.trailingText ?? ""
        let expectedTrailing = trailing ?? ""
        Self.require(
            state.title == title && state.trailingText == trailing && state.isEnabled == enabled,
            "\(step): row read \"\(state.title)\" trailing \"\(actualTrailing)\" "
                + "(enabled: \(state.isEnabled)), expected \"\(title)\" trailing "
                + "\"\(expectedTrailing)\" (enabled: \(enabled))"
        )
    }


    /// The only way out, so the throwaway domain is dropped on the failing paths too. `defer`
    /// cannot do this job: `exit()` terminates the process without unwinding the stack.
    private static func finish(_ code: Int32) -> Never {
        EphemeralDefaults.clear(Self.suite)
        exit(code)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { Self.fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        VerifierReport.report(message, label: "refresh-row verification")
        Self.finish(1)
    }
}
#endif
