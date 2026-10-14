import QuotaBarCore
import AppKit
import SwiftUI

/// Single settings window. The app is an accessory, so it has to activate itself to take focus.
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let pricing: PricingTableModel
    private let export: ExportSettingsModel
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(
        settings: SettingsStore,
        pricing: PricingTableModel,
        export: ExportSettingsModel? = nil
    ) {
        self.settings = settings
        self.pricing = pricing
        self.export = export ?? ExportSettingsModel()
    }

    func show() {
        let window = self.window ?? self.makeWindow()
        // A window that is already on screen keeps wherever the user put it; one that is being
        // opened lands in the middle of the active screen.
        if !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The window outlives being closed, so a reopened pricing pane rereads its rates.
        if self.selection.tab == .pricing { self.selection.pricingReloads += 1 }
    }

    func showPricing() {
        self.selection.tab = .pricing
        self.show()
    }

    func showExport() {
        self.selection.tab = .export
        self.show()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: self.settings, pricing: self.pricing, export: self.export,
                                   selection: self.selection)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuotaBar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // SwiftUI settles the content size only after a layout pass; centering the pre-layout
        // frame is what left the window sitting off-centre.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        self.window = window
        return window
    }
}
