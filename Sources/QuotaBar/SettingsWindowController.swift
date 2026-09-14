import QuotaBarCore
import AppKit
import SwiftUI

/// Single settings window. The app is an accessory, so it has to activate itself to take focus.
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let pricing: PricingEditorModel
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(settings: SettingsStore, pricing: PricingEditorModel) {
        self.settings = settings
        self.pricing = pricing
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
    }

    func showPricing() {
        self.selection.tab = .pricing
        self.show()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard self.pricing.hasUnsavedChanges else { return .terminateNow }
        if self.pricing.saveStatus == .saving {
            Task {
                while self.pricing.saveStatus == .saving {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let saved = !self.pricing.hasUnsavedChanges
                if !saved { self.showPricing() }
                application.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let valid = self.pricing.invalidFieldCount == 0
        alert.messageText = valid ? "Save price changes before quitting?" : "Price changes need correction"
        alert.informativeText = valid
            ? "Save the edited rates, discard the draft, or keep editing."
            : "Fix the invalid fields before saving, discard the draft, or keep editing."
        if valid { alert.addButton(withTitle: "Save") }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if !valid {
            // Return should keep an invalid draft open, not discard it accidentally.
            alert.buttons.first?.keyEquivalent = ""
            alert.buttons.last?.keyEquivalent = "\r"
        }
        let response = alert.runModal()

        if valid && response == .alertFirstButtonReturn {
            Task {
                let saved = await self.pricing.save()
                if !saved { self.showPricing() }
                application.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        let discardResponse: NSApplication.ModalResponse = valid
            ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if response == discardResponse {
            self.pricing.discard()
            return .terminateNow
        }
        self.showPricing()
        return .terminateCancel
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: self.settings, pricing: self.pricing,
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
