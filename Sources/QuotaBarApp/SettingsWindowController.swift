import QuotaBarCore
import AppKit
import SwiftUI

/// Single settings window. The app is an accessory, so it has to activate itself to take focus.
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let pricing: PricingTableModel
    private let store: UsageStore
    private let backup: UsageBackupModel
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(settings: SettingsStore, pricing: PricingTableModel, store: UsageStore) {
        self.settings = settings
        self.pricing = pricing
        self.store = store
        self.backup = UsageBackupModel(settings: settings, store: store)
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
        // The window outlives being closed, so a reopened window rereads its rates.
        self.selection.windowShows += 1
        if self.selection.tab == .pricing { self.selection.pricingReloads += 1 }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: self.settings, pricing: self.pricing,
                                   store: self.store, backup: self.backup, selection: self.selection)
        )
        // SwiftUI would add the title bar's safe area to the height, but the sidebar runs up
        // behind the title bar, so the window is sized here instead.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuotaBar Settings"
        // The title stays for the Window menu and assistive technology; the sidebar names the app.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsView.windowSize)
        self.window = window
        return window
    }
}
