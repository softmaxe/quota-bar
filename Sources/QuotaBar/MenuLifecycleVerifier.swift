#if DEBUG
import QuotaBarCore
import AppKit
import Foundation

/// Exercises the real controller without provider requests or user preferences.
@MainActor
enum MenuLifecycleVerifier {
    static func benchmark() -> Never { self.run(benchmarkOnly: true) }
    static func run() -> Never { self.run(benchmarkOnly: false) }
    static func verifyInteraction() -> Never { self.run(benchmarkOnly: false, verifyInteraction: true) }

    private static func run(benchmarkOnly: Bool, verifyInteraction: Bool = false) -> Never {
        let suite = "QuotaBarMenuLifecycleVerifier"
        let defaults = EphemeralDefaults.make(suite)
        func finish(_ code: Int32) -> Never {
            defaults.removePersistentDomain(forName: suite)
            exit(code)
        }
        func require(_ condition: Bool, _ message: String) {
            if !condition {
                VerifierReport.report(message, label: "menu-lifecycle verification")
                finish(1)
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let settings = SettingsStore(defaults: defaults)
        let service = CostService(pricingOverlay: PricingOverlay())
        let store = UsageStore(settings: settings, costService: service, clock: { 1_000 }, recoveryDefaults: defaults)
        var reduceMotion = false
        let started = ContinuousClock.now
        let controller = StatusItemController(
            store: store, settings: settings,
            pricing: PricingEditorModel(costService: service),
            // The fallback accepts in-process events; native sessions require real menu bar input.
            useSystemStatusItemSession: !verifyInteraction,
            reduceMotion: { reduceMotion }
        )
        let elapsed = started.duration(to: .now)
        print(String(format: "status_item_init_ms=%.3f menu_created=%@",
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15,
            controller.debugHasMenu ? "yes" : "no"))
        if benchmarkOnly { finish(0) }
        PopoverInputActivationVerifier.run()
        require(!controller.debugHasMenu, "startup eagerly built the hidden menu")

        // No observers are started on the store, and both cooldowns are pinned, so even
        // opening the actual menu delegate cannot initiate a provider or cost request.
        for provider in Provider.allCases { store.debugRecordRefresh(at: 1_000, provider: provider) }
        var display = ProviderDisplay()
        display.error = "Offline fixture"
        store.debugSetDisplay(display, for: settings.menuBarProvider)
        RunLoopDrain.run()
        require(!controller.debugHasMenu, "a background update built the hidden menu")

        controller.debugBeginPresentation()
        require(controller.debugHasMenu, "opening did not build the menu")
        require(controller.debugStatusLine() == "Refresh failed", "first open lost the latest state")
        controller.debugEndPresentation()
        let updates = controller.debugCardUpdateCount
        display.isSignedOut = true
        store.debugSetDisplay(display, for: settings.menuBarProvider)
        RunLoopDrain.run()
        require(controller.debugCardUpdateCount == updates, "background updates laid out a closed card")
        controller.debugBeginPresentation()
        require(controller.debugStatusLine() == "Not signed in", "reopening showed stale state")
        require(controller.debugCardUpdateCount > updates, "reopening did not update the card")

        settings.menuBarProvider = Provider.allCases.first { $0 != settings.menuBarProvider }!
        require(controller.debugStatusLine() == "No data yet", "provider switch kept the old card")
        controller.debugEndPresentation()
        if !verifyInteraction {
            print("Menu creation is deferred; closed cards stay idle and reopen with current state")
            finish(0)
        }

        // Exercise the real button and popover with another app left in the foreground.
        // Status-item placement arrives asynchronously from the system menu bar.
        NSApp.finishLaunching()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let window = controller.debugStatusItemButton?.window,
               let screen = window.screen, window.frame.intersects(screen.frame) { break }
            RunLoopDrain.run()
        }
        guard let button = controller.debugStatusItemButton, let anchor = button.window else {
            require(false, "the status button was unavailable")
            finish(1)
        }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var shows = 0
        var closes = 0
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didShowNotification, object: nil, queue: .main
        ) { _ in shows += 1 }
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: .main
        ) { _ in closes += 1 }
        func waitForDismissal(line: UInt = #line) {
            let deadline = Date().addingTimeInterval(2)
            while controller.debugIsPopoverShown, Date() < deadline {
                RunLoopDrain.run(for: 0.01)
            }
            require(!controller.debugIsPopoverShown,
                    "dismissal did not finish at line \(line): shows=\(shows) closes=\(closes)")
        }
        func clickStatusButton(rightClick: Bool = false, timestamp: TimeInterval? = nil, expectsToggle: Bool = true) {
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let timestamp = timestamp ?? ProcessInfo.processInfo.systemUptime
            let wasShown = controller.debugIsPopoverShown
            let downType: NSEvent.EventType = rightClick ? .rightMouseDown : .leftMouseDown
            let upType: NSEvent.EventType = rightClick ? .rightMouseUp : .leftMouseUp
            let downMask: NSEvent.EventTypeMask = rightClick ? .rightMouseDown : .leftMouseDown
            let upMask: NSEvent.EventTypeMask = rightClick ? .rightMouseUp : .leftMouseUp
            guard let down = NSEvent.mouseEvent(
                with: downType, location: location, modifierFlags: [], timestamp: timestamp,
                windowNumber: anchor.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: upType, location: location, modifierFlags: [], timestamp: timestamp + 0.05,
                windowNumber: anchor.windowNumber, context: nil, eventNumber: 2,
                clickCount: 1, pressure: 0
            ) else {
                require(false, "could not construct the status-button mouse events")
                return
            }
            // Dispatch both halves through NSApplication, with a separate release turn.
            // performClick does not cover the status button's native mouse tracking.
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(down, atStart: true)
            let deadline = Date().addingTimeInterval(0.1)
            guard let press = NSApp.nextEvent(matching: downMask, until: deadline,
                                              inMode: .default, dequeue: true) else {
                require(false, "the status-button press was not dispatched")
                return
            }
            NSApp.sendEvent(press)
            if wasShown && !rightClick && expectsToggle { waitForDismissal() }
            let shownAfterPress = controller.debugIsPopoverShown
            require(shownAfterPress == (rightClick || !expectsToggle ? wasShown : !wasShown),
                    "the status-button press toggled at the wrong phase")
            require(controller.debugIsStatusItemSelected == shownAfterPress,
                    "the pressed status background disagreed with the popover")
            require(!button.isHighlighted, "native mouse tracking added a second pressed background")
            guard let release = NSApp.nextEvent(matching: upMask, until: deadline,
                                                inMode: .default, dequeue: true) else {
                require(false, "native mouse tracking consumed the release after toggling")
                return
            }
            NSApp.sendEvent(release)
            if wasShown && rightClick && expectsToggle { waitForDismissal() }
            let expectedShown = expectsToggle ? !wasShown : wasShown
            require(controller.debugIsPopoverShown == expectedShown,
                    "the mouse click was not handled exactly once")
            require(controller.debugIsStatusItemSelected == expectedShown,
                    "mouse release overwrote the popover's status background")
        }
        clickStatusButton()
        require(!controller.debugPopoverAnimates, "opening used the native popover zoom")
        require(controller.debugIsMonitoringDismissal, "opening did not immediately accept dismissal")
        RunLoopDrain.run(for: 0.1)
        require(controller.debugIsPopoverShown, "a status-button click did not keep the popover open")
        require(controller.debugIsStatusItemSelected, "mouse release cleared the open status background")
        require(controller.debugPopoverWindow?.isKeyWindow == true, "the popover did not receive keyboard focus")
        require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                "opening the popover switched the foreground application")

        func click(in window: NSWindow) {
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1
            ) else {
                require(false, "could not construct the local click fixture")
                return
            }
            controller.debugDismissForLocalClick(event)
        }
        click(in: anchor)
        require(controller.debugIsPopoverShown, "the dismissal monitor closed before the toggle action")
        let statusBounds = anchor.convertToScreen(button.convert(button.bounds, to: nil))
        // The system menu bar reports a global press before forwarding the same click
        // to our status button. That first notification must not close the popover.
        controller.debugDismissForGlobalClick(at: NSPoint(x: statusBounds.midX, y: statusBounds.midY))
        require(controller.debugIsPopoverShown && controller.debugIsStatusItemSelected,
                "the remote status-item click was misclassified as an outside click")
        clickStatusButton()
        RunLoopDrain.run()
        require(!controller.debugIsPopoverShown && !controller.debugIsStatusItemSelected,
                "a second click did not close the popover and clear the status background")
        require(shows == 1 && closes == 1, "one toggle click closed and reopened the popover")

        clickStatusButton(rightClick: true)
        clickStatusButton(rightClick: true)
        require(shows == 2 && closes == 2, "right clicks did not toggle exactly once on release")

        clickStatusButton()
        controller.debugDismissForGlobalClick(at: NSPoint(x: statusBounds.maxX + 20, y: statusBounds.midY))
        waitForDismissal()
        require(!controller.debugIsPopoverShown && !controller.debugIsStatusItemSelected,
                "a global click outside the status item did not dismiss the card")

        clickStatusButton()
        RunLoopDrain.run()
        guard let window = controller.debugPopoverWindow,
              let providerKey = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "1",
                charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
              ) else {
            require(false, "the popover keyboard fixture was unavailable")
            finish(1)
        }
        require(window.performKeyEquivalent(with: providerKey), "the popover did not handle Cmd-1")
        require(settings.menuBarProvider == .codex, "Cmd-1 did not change the provider")
        if let window = controller.debugPopoverWindow { click(in: window) }
        require(controller.debugIsPopoverShown, "a click inside the card dismissed it")
        let menuWindow = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        menuWindow.level = .popUpMenu
        click(in: menuWindow)
        require(controller.debugIsPopoverShown, "a nested menu click dismissed the card")
        let otherWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        click(in: otherWindow)
        waitForDismissal()
        require(!controller.debugIsPopoverShown && !controller.debugIsStatusItemSelected,
                "a different window in this app left the popover or status background open")
        // Accessibility activation still uses the button's target/action path.
        button.performClick(nil)
        RunLoopDrain.run()
        guard let escapeWindow = controller.debugPopoverWindow,
              let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: escapeWindow.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else {
            require(false, "the Escape fixture was unavailable")
            finish(1)
        }
        // A preference change while the card is open also applies to its dismissal.
        reduceMotion = true
        NSApp.sendEvent(escape)
        waitForDismissal()
        require(!controller.debugIsPopoverClosing, "dismissal ignored Reduce Motion")
        require(!controller.debugIsPopoverShown && !controller.debugIsStatusItemSelected,
                "Escape did not close the card and clear its status background")
        clickStatusButton()
        require(!controller.debugPopoverAnimates, "reopening used the native popover zoom")
        clickStatusButton()
        reduceMotion = false
        clickStatusButton()
        let fadingWindow = controller.debugPopoverWindow
        controller.debugDismissForGlobalClick(at: NSPoint(x: statusBounds.maxX + 20, y: statusBounds.midY))
        require(controller.debugIsPopoverClosing, "dismissal kept a stale Reduce Motion preference")
        require(!controller.debugIsStatusItemSelected, "dismissal delayed clearing the status selection")
        require(!controller.debugIsMonitoringDismissal, "dismissal delayed removing its input monitors")
        require(fadingWindow?.ignoresMouseEvents == true, "the fading card still accepted mouse input")
        let providerBeforeFade = settings.menuBarProvider
        if let fadingWindow, let providerKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: fadingWindow.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19
        ) {
            NSApp.sendEvent(providerKey)
        } else {
            require(false, "the fading card keyboard fixture was unavailable")
        }
        require(settings.menuBarProvider == providerBeforeFade, "the fading card still accepted keyboard input")
        require(NSApp.keyWindow == nil || NSApp.keyWindow?.isKeyWindow == true,
                "dismissal left inconsistent key-window ownership")
        RunLoopDrain.run(for: 0.05)
        button.performClick(nil)
        require(controller.debugIsPopoverShown && !controller.debugIsPopoverClosing,
                "a click during dismissal did not reopen the card")
        require(controller.debugPopoverWindow === fadingWindow, "reopening replaced the fading card's window")
        require(fadingWindow?.ignoresMouseEvents == false, "reopening left the card unresponsive")
        RunLoopDrain.run(for: 0.3)
        require(controller.debugIsPopoverShown && controller.debugIsStatusItemSelected,
                "an obsolete dismissal completion closed the reopened card")
        require(fadingWindow?.alphaValue == 1, "an obsolete fade dimmed the reopened card")
        // A remote status click can arrive globally before its local mouse events.
        controller.debugDismissForGlobalClick(at: NSPoint(x: statusBounds.maxX + 20, y: statusBounds.midY))
        let reopenTimestamp = ProcessInfo.processInfo.systemUptime
        controller.debugDismissForGlobalClick(
            at: NSPoint(x: statusBounds.midX, y: statusBounds.midY), timestamp: reopenTimestamp
        )
        require(controller.debugIsPopoverShown && !controller.debugIsPopoverClosing,
                "the remote status click did not reverse dismissal")
        clickStatusButton(timestamp: reopenTimestamp, expectsToggle: false)
        RunLoopDrain.run(for: 0.3)
        require(controller.debugIsPopoverShown && fadingWindow?.alphaValue == 1,
                "the forwarded remote click or stale fade closed the reopened card")
        reduceMotion = true
        controller.debugDismissForGlobalClick(at: NSPoint(x: statusBounds.maxX + 20, y: statusBounds.midY))
        require(!controller.debugIsPopoverShown && !controller.debugIsPopoverClosing,
                "Reduce Motion did not dismiss the card immediately")
        require(NSApp.keyWindow !== fadingWindow && fadingWindow?.isKeyWindow == false,
                "closing did not release the key window")
        NotificationCenter.default.removeObserver(showObserver)
        NotificationCenter.default.removeObserver(closeObserver)
        print("Menu lifecycle, status-button toggling, dismissal, and foreground preservation checks passed")
        finish(0)
    }
}
#endif
