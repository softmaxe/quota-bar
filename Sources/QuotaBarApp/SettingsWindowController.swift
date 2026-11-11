import QuotaBarCore
import AppKit
import SwiftUI

/// Single settings window. The app is an accessory, so it has to activate itself to take focus.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let pricing: PricingTableModel
    private let store: UsageStore
    private let backup: UsageBackupModel
    private let selection = SettingsSelection()
    let clock = SettingsClock()
    private(set) var window: NSWindow?
    private var isPositioning = false

    init(settings: SettingsStore, pricing: PricingTableModel, store: UsageStore) {
        self.settings = settings
        self.pricing = pricing
        self.store = store
        self.backup = UsageBackupModel(store: store)
        super.init()
    }

    func show() {
        let window = self.window ?? self.makeWindow()
        if !window.isVisible {
            window.layoutIfNeeded()
            let screens = NSScreen.screens
            let current = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main ?? screens.first
            if let current {
                self.isPositioning = true
                window.setFrameOrigin(SettingsWindowPlacement.origin(
                    saved: self.settings.settingsWindowPosition, size: window.frame.size,
                    visibleFrames: screens.map(\.visibleFrame), current: current.visibleFrame
                ))
                self.isPositioning = false
                self.savePosition(window)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.updateClock(window)
        // The window outlives being closed, so a reopened window rereads its rates.
        self.selection.windowShows += 1
        if self.selection.tab == .pricing { self.selection.pricingReloads += 1 }
    }

    func windowDidMove(_ notification: Notification) {
        guard !self.isPositioning, let window = notification.object as? NSWindow else { return }
        self.savePosition(window)
    }

    func windowWillClose(_ notification: Notification) {
        self.clock.setActive(false)
        guard let window = notification.object as? NSWindow else { return }
        self.savePosition(window)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        self.updateClock(window)
    }

    private func updateClock(_ window: NSWindow) {
        self.clock.setActive(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func savePosition(_ window: NSWindow) {
        self.settings.settingsWindowPosition = .init(x: window.frame.origin.x, y: window.frame.origin.y)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(settings: self.settings, pricing: self.pricing,
                                   store: self.store, backup: self.backup, selection: self.selection, clock: self.clock)
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
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        self.window = window
        return window
    }
}

enum SettingsWindowPlacement {
    /// Preserve reachable positions, fit partially clipped windows, and recenter after a display
    /// disconnect. Screen coordinates may legitimately be zero or negative.
    static func origin(saved: SettingsWindowPosition?, size: NSSize,
                       visibleFrames: [NSRect], current: NSRect) -> NSPoint {
        if let saved, saved.x.isFinite, saved.y.isFinite {
            let frame = NSRect(origin: NSPoint(x: saved.x, y: saved.y), size: size)
            if let screen = visibleFrames.max(by: { intersectionArea(frame, $0) < intersectionArea(frame, $1) }),
               intersectionArea(frame, screen) > 0 {
                return NSPoint(x: min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - size.width)),
                               y: min(max(frame.minY, screen.minY), screen.maxY - size.height))
            }
        }
        return NSPoint(x: current.midX - size.width / 2,
                       y: min(max(current.minY, current.midY - size.height / 2), current.maxY - size.height))
    }

    private static func intersectionArea(_ frame: NSRect, _ screen: NSRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
