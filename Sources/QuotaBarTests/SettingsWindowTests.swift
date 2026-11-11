@testable import QuotaBarApp
import AppKit
import QuotaBarCore

@MainActor
enum SettingsWindowTests {
    static func run() async {
        let main = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let left = NSRect(x: -1440, y: 24, width: 1440, height: 876)
        let size = NSSize(width: 800, height: 560)
        func origin(_ saved: SettingsWindowPosition?, screens: [NSRect] = [main, left]) -> NSPoint {
            SettingsWindowPlacement.origin(saved: saved, size: size, visibleFrames: screens, current: main)
        }
        Harness.expectEqual(origin(nil), NSPoint(x: 320, y: 182), "first open centers in the usable screen")
        Harness.expectEqual(origin(.init(x: -1200, y: 100)), NSPoint(x: -1200, y: 100),
                            "a saved position on another display wins over the current screen")
        Harness.expectEqual(origin(.init(x: 0, y: 24)), NSPoint(x: 0, y: 24), "zero is a valid coordinate")
        Harness.expectEqual(origin(.init(x: 1200, y: 800)), NSPoint(x: 640, y: 340),
                            "a clipped window fits within the remaining usable area")
        Harness.expectEqual(origin(.init(x: -1200, y: 100), screens: [main]), origin(nil),
                            "disconnecting the remembered display recenters the window")
        Harness.expectEqual(origin(.init(x: .infinity, y: 0)), origin(nil), "invalid coordinates recenter")

        await AppCheck.run("settings position persistence and close/reopen") {
            let suite = "QuotaBarSettingsWindowTests"
            let otherSuite = "QuotaBarSettingsWindowTestsOther"
            let defaults = EphemeralDefaults.make(suite)
            let other = EphemeralDefaults.make(otherSuite)
            defer {
                EphemeralDefaults.clear(suite)
                EphemeralDefaults.clear(otherSuite)
            }
            let settings = SettingsStore(defaults: defaults)
            try AppCheck.require(settings.settingsWindowPosition == nil, "missing position became zero")
            settings.settingsWindowPosition = .init(x: -100, y: 0)
            try AppCheck.require(SettingsStore(defaults: defaults).settingsWindowPosition == .init(x: -100, y: 0),
                                 "a new store lost the position")
            try AppCheck.require(SettingsStore(defaults: other).settingsWindowPosition == nil,
                                 "position escaped its preference suite")
            defaults.set(Data("broken".utf8), forKey: "settingsWindowPosition")
            try AppCheck.require(settings.settingsWindowPosition == nil, "corrupt data was accepted")
            settings.settingsWindowPosition = .init(x: .nan, y: 0)
            try AppCheck.require(settings.settingsWindowPosition == nil, "nonfinite data was persisted")

            NSApplication.shared.setActivationPolicy(.accessory)
            let service = CostService(rateCard: RateCard())
            let store = UsageStore(settings: settings, costService: service, recoveryDefaults: defaults)
            defer { store.stop() }
            let pricing = PricingTableModel(costService: service, fixtures: .init(usage: [:]))
            @MainActor func controller(_ settings: SettingsStore) -> SettingsWindowController {
                SettingsWindowController(settings: settings, pricing: pricing, store: store)
            }
            let first = controller(settings)
            first.show()
            guard let window = first.window, let screen = window.screen else {
                throw CheckFailure(description: "settings window has no screen")
            }
            defer { window.close() }
            let moved = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - window.frame.height - 40)
            window.setFrameOrigin(moved)
            try AppCheck.require(settings.settingsWindowPosition == .init(x: moved.x, y: moved.y),
                                 "moving the window did not save immediately")
            window.close()
            try AppCheck.require(!first.clock.isRunning, "closing settings left its clock running")
            first.show()
            try AppCheck.require(window.frame.origin == moved, "reopening centered the moved window")
            window.close()
            let next = controller(SettingsStore(defaults: defaults))
            next.show()
            defer { next.window?.close() }
            try AppCheck.require(next.window?.frame.origin == moved, "recreating the controller lost the position")
        }
    }
}
