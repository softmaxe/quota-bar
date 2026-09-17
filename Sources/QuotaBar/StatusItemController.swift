import QuotaBarCore
import AppKit
import Combine
import SwiftUI

/// A native popover gives the compact card normal keyboard and button behavior.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuItemValidation {
    private let store: UsageStore
    private let settings: SettingsStore
    private let settingsWindow: SettingsWindowController
    private let now: () -> Date
    private let openMenuClockInterval: TimeInterval
    private let refreshRowClockInterval: TimeInterval
    private let useSystemStatusItemSession: Bool
    private var systemManagesStatusItem = false
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var presentation: MenuPopoverModel?
    private var cancellables: Set<AnyCancellable> = []
    private var isMenuOpen = false
    private var openMenuClock: Timer?
    private var refreshRowClock: Timer?
    private var statusItemMouseMonitor: Any?
    private var capturedStatusMouseButton: Int?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var workspaceDismissalObservers: [NSObjectProtocol] = []
    private var recoveries: [Provider: [QuotaWindowKind: QuotaRecoveryEvent]] = [:]
    private var celebrationTokens: [Provider: [QuotaWindowKind: Int]] = [:]
    private var isCostBreakdownExpanded = false
    private var expandedBreakdownDayKey: String?
    private var presentedProvider: Provider?

    init(store: UsageStore, settings: SettingsStore, pricing: PricingEditorModel,
         now: @escaping () -> Date = { Date() },
         openMenuClockInterval: TimeInterval = 15, refreshRowClockInterval: TimeInterval = 1,
         useSystemStatusItemSession: Bool = true) {
        self.store = store
        self.settings = settings
        self.settingsWindow = SettingsWindowController(settings: settings, pricing: pricing)
        self.now = now
        self.openMenuClockInterval = openMenuClockInterval
        self.refreshRowClockInterval = refreshRowClockInterval
        self.useSystemStatusItemSession = useSystemStatusItemSession
        super.init()
        pricing.onSaved = { [weak store] in store?.refreshCostsAfterPricingChange() }
        self.settings.$menuBarProvider.removeDuplicates().sink { [weak self] provider in
            self?.apply(provider: provider)
        }.store(in: &self.cancellables)
        self.store.$displays.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.apply()
        }.store(in: &self.cancellables)
        self.store.$refreshingProviders.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshOpenCard()
        }.store(in: &self.cancellables)
    }

    deinit {
        if let statusItemMouseMonitor { NSEvent.removeMonitor(statusItemMouseMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        for observer in self.workspaceDismissalObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let commands = NSMenu(title: "QuotaBar")
        for (title, action, key) in [
            ("Refresh", #selector(self.refreshClicked), "r"),
            ("Settings…", #selector(self.settingsClicked), ","),
            ("Quit QuotaBar", #selector(self.quitClicked), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            commands.addItem(item)
        }
        applicationItem.submenu = commands
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key, shift) in [
            ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false)
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            edit.addItem(item)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    func showExportSettings() {
        self.popover?.performClose(nil)
        self.settingsWindow.showExport()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(self.refreshClicked)
            || self.store.canRefresh(self.settings.menuBarProvider)
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        self.popover?.performClose(nil)
        return self.settingsWindow.applicationShouldTerminate(application)
    }

    private func apply(provider: Provider? = nil) {
        let provider = provider ?? self.settings.menuBarProvider
        let display = self.store.displays[provider] ?? ProviderDisplay()
        let item = self.materializedStatusItem()
        item.button?.image = IconRenderer.makeIcon(
            hasReading: display.snapshot?.session != nil || display.snapshot?.weekly != nil,
            stale: display.isStale,
            runningLow: display.snapshot.map { MenuBarProviderPolicy.runningLow($0, now: self.now()) } ?? false
        )
        item.button?.toolTip = self.toolTip(for: provider, display: display)
        item.button?.setAccessibilityLabel("QuotaBar, \(provider.displayName)")
        self.updateCard(provider: provider, display: display)
    }

    private func materializedStatusItem() -> NSStatusItem {
        if let item = self.statusItem { return item }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "quotabar"
        self.statusItem = item
        // AppKit 2775 is the macOS 27 SDK. Older SDKs keep the legacy event path.
#if canImport(AppKit, _version: 2775)
        if #available(macOS 27, *), self.useSystemStatusItemSession {
            self.systemManagesStatusItem = true
            item.expandedInterfaceDelegate = self
        }
#endif
        if !self.systemManagesStatusItem {
            item.button?.target = self
            item.button?.action = #selector(self.statusItemClicked)
            // Keep the selection visible for the whole presentation. Mouse tracking must not
            // clear and redraw the status background when the press ends.
            if let cell = item.button?.cell as? NSButtonCell {
                cell.highlightsBy = []
                cell.showsStateBy = [.changeBackgroundCellMask]
            }
        }
        // Consume pointer input before NSButton starts its tracking loop. That loop can
        // redraw the pressed background after our action has already closed the popover.
        // Keep target/action above for accessibility and keyboard activation.
        self.statusItemMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                       .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleStatusItemMouseEvent(event)
        }
        return item
    }

    private func handleStatusItemMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard let button = self.statusItem?.button else { return event }
        let isInside = event.window === button.window
            && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            self.capturedStatusMouseButton = nil
            // Preserve the system's Command-drag gesture for rearranging menu bar items.
            guard isInside, !event.modifierFlags.contains(.command) else { return event }
            if self.systemManagesStatusItem {
                // AppKit opens and highlights the system session. A repeated press only
                // closes it; swallowing the release prevents the same click reopening it.
                guard self.popover?.isShown == true else { return event }
                self.capturedStatusMouseButton = event.buttonNumber
                if event.type == .leftMouseDown {
                    self.popover?.performClose(nil)
                }
                return nil
            }
            self.capturedStatusMouseButton = event.buttonNumber
            if event.type == .leftMouseDown { self.statusItemClicked() }
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard self.capturedStatusMouseButton == event.buttonNumber else { return event }
            self.capturedStatusMouseButton = nil
            if event.type == .rightMouseUp, isInside {
                if self.systemManagesStatusItem {
                    self.popover?.performClose(nil)
                } else {
                    self.statusItemClicked()
                }
            }
            return nil
        case .leftMouseDragged, .rightMouseDragged:
            return self.capturedStatusMouseButton == event.buttonNumber ? nil : event
        default:
            return event
        }
    }

    private func toolTip(for provider: Provider, display: ProviderDisplay) -> String {
        var parts = [provider.displayName]
        if let snapshot = display.snapshot {
            if let session = snapshot.session {
                parts.append("session \(Formatters.percent(session.remainingPercent)) left")
            } else if snapshot.sessionIsUnlimited {
                parts.append("session no limit")
            }
            if let weekly = snapshot.weekly {
                parts.append("weekly \(Formatters.percent(weekly.remainingPercent)) left")
            }
        }
        if display.isSignedOut { parts.append("Not signed in") }
        if let error = display.error { parts.append(error) }
        for other in Provider.allCases where other != provider {
            if let snapshot = self.store.displays[other]?.snapshot,
               let remaining = MenuBarProviderPolicy.tightestRemaining(snapshot, now: self.now()) {
                parts.append("\(other.displayName) \(Formatters.percent(remaining)) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    @objc private func statusItemClicked() {
        if self.popover?.isShown == true {
            self.popover?.performClose(nil)
            return
        }
        self.showPopover()
    }

    private func showPopover() {
        guard self.popover?.isShown != true else { return }
        guard let button = self.statusItem?.button else { return }
        let popover = self.materializedPopover()
        self.presentation?.maximumHeight = max(160, (button.window?.screen?.visibleFrame.height ?? 800) - 120)
        self.beginPresentation()
        // The popover can take keyboard focus without activating the entire app, which
        // would redraw the menu bar and deactivate the user's foreground window.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else {
            self.endPresentation()
            return
        }
        if let content = popover.contentViewController?.view, let window = content.window {
            window.makeKey()
            window.makeFirstResponder(content)
        }
    }

    private func materializedPopover() -> NSPopover {
        if let popover = self.popover { return popover }
        let provider = self.settings.menuBarProvider
        let model = MenuPopoverModel(
            card: self.makeCard(provider: provider, display: self.store.displays[provider] ?? ProviderDisplay()),
            provider: provider
        )
        model.onRefresh = { [weak self] in self?.refreshClicked() }
        model.onSettings = { [weak self] in self?.settingsClicked() }
        model.onQuit = { [weak self] in self?.quitClicked() }
        model.onClose = { [weak self] in self?.popover?.performClose(nil) }
        model.onSizeChanged = { [weak self] in self?.updatePopoverSize() }
        let popover = NSPopover()
        // Own dismissal so AppKit cannot close the popover before the status-button
        // action and turn the same click into another open.
        popover.behavior = .applicationDefined
        // The native popover keeps anchoring. Its default opening
        // animation adds a wait to this frequent glance; local controls provide feedback.
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = MenuPopoverHostingController(rootView: MenuPopoverView(model: model))
        self.presentation = model
        self.popover = popover
        return popover
    }

    private func makeCard(provider: Provider, display: ProviderDisplay) -> MenuCardView {
        MenuCardView(
            provider: provider, display: display, isRefreshing: self.store.isRefreshing(provider),
            recoveries: self.recoveries[provider] ?? [:],
            celebrationTokens: self.celebrationTokens[provider] ?? [:], now: self.now(),
            costChartLabelMode: self.settings.costChartLabelMode,
            onCostChartLabelModeChanged: { [weak self] mode in
                self?.settings.costChartLabelMode = mode
                self?.refreshOpenCard()
            },
            isCostBreakdownExpanded: self.isCostBreakdownExpanded,
            expandedCostBreakdownDayKey: self.expandedBreakdownDayKey,
            onCostBreakdownExpandedChanged: { [weak self] expanded, dayKey in
                self?.isCostBreakdownExpanded = expanded
                self?.expandedBreakdownDayKey = expanded ? dayKey : nil
                self?.refreshOpenCard()
            },
            quotaResetDisplayMode: self.settings.quotaResetDisplayMode,
            onQuotaResetDisplayModeChanged: { [weak self] mode in
                self?.settings.quotaResetDisplayMode = mode
                self?.refreshOpenCard()
            },
            onProviderSelected: { [weak self] provider in self?.settings.menuBarProvider = provider },
            onRefresh: { [weak self] in self?.refreshClicked() },
            onOpenPricing: { [weak self] in
                self?.popover?.performClose(nil)
                self?.settingsWindow.showPricing()
            },
            onRefreshLocalUsage: { [weak self] in self?.store.retryLocalUsage() }
        )
    }

    private func updateCard(provider: Provider, display: ProviderDisplay) {
        guard self.isMenuOpen, let presentation = self.presentation else { return }
#if DEBUG
        self.debugCardUpdateCount += 1
#endif
        if self.presentedProvider != provider {
            self.isCostBreakdownExpanded = false
            self.expandedBreakdownDayKey = nil
            self.presentedProvider = provider
        }
        let events = self.store.consumeCelebrations(for: provider)
        self.recoveries[provider, default: [:]].merge(events) { _, new in new }
        for kind in events.keys { self.celebrationTokens[provider, default: [:]][kind, default: 0] += 1 }
        let card = self.makeCard(provider: provider, display: display)
        presentation.provider = provider
        presentation.card = card
        presentation.showsRefresh = !display.isSignedOut
        // Measure the first frame before presentation. Local disclosures report later sizes.
        if presentation.contentHeight == 0 || provider != presentation.measuredProvider {
            presentation.contentHeight = NSHostingView(rootView: card).fittingSize.height.rounded(.up)
            presentation.measuredProvider = provider
        }
        self.updateRefreshRow()
        self.updatePopoverSize()
    }

    private func refreshOpenCard() {
        let provider = self.settings.menuBarProvider
        self.updateCard(provider: provider, display: self.store.displays[provider] ?? ProviderDisplay())
    }

    private func updatePopoverSize() {
        guard let model = self.presentation else { return }
        let size = NSSize(width: 280, height: model.viewportHeight + model.footerHeight)
        guard let popover = self.popover, popover.contentSize != size else { return }
        // Resizing the host during a SwiftUI transition moves every line in the popover.
        // Local controls animate their own feedback after the content takes its final size.
        let animates = popover.animates
        popover.animates = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popover.contentSize = size
        }
        popover.animates = animates
    }

    @objc private func refreshClicked() {
        let provider = self.settings.menuBarProvider
        guard self.store.canRefresh(provider) else { return }
        let recovery = self.store.displays[provider]?.canAttemptCredentialRecovery == true
        self.store.refresh(force: recovery, interaction: .userInitiated)
        self.updateRefreshRow()
    }

    private func updateRefreshRow() {
        guard self.isMenuOpen, let presentation = self.presentation else { return }
        let provider = presentation.provider
        let display = self.store.displays[provider] ?? ProviderDisplay()
        let allowsRecovery = display.canAttemptCredentialRecovery && self.store.canRefresh(provider)
        presentation.refreshState = RefreshRowPolicy.state(
            cooldownRemaining: self.store.cooldownRemaining(for: provider),
            isRefreshing: self.store.isRefreshing(provider),
            allowsCredentialRecovery: allowsRecovery,
            action: display.isSignedOut ? .checkSignIn : .refresh
        )
    }

    @objc private func settingsClicked() {
        self.popover?.performClose(nil)
        self.settingsWindow.show()
    }
    @objc private func quitClicked() { NSApp.terminate(nil) }

    private func beginPresentation() {
        _ = self.materializedPopover()
        self.store.refresh()
        self.isMenuOpen = true
        self.recoveries = [:]
        self.isCostBreakdownExpanded = false
        self.expandedBreakdownDayKey = nil
        self.presentedProvider = nil
        self.presentation?.presentationID = UUID()
        // A closed card may have changed or been left expanded. Measure its collapsed state
        // before showing it, so the first visible frame already has the correct height.
        self.presentation?.measuredProvider = nil
        self.refreshOpenCard()
        self.startOpenMenuClock()
        self.startRefreshRowClock()
    }

    func popoverDidShow(_ notification: Notification) {
        self.stopDismissalMonitoring()
        self.localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.dismissForLocalClick(event)
            return event
        }
        // A system session owns the highlight. Pointer dismissal still needs to cancel
        // it explicitly when the popover takes keyboard focus without app activation.
        if !self.systemManagesStatusItem { self.statusItem?.button?.state = .on }
        // The remote menu bar can report its own clicks globally. The legacy path
        // excludes the icon; a system session needs that click to cancel its interface.
        self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            let location: NSPoint
            if let point = event.cgEvent?.location, let primaryScreen = NSScreen.screens.first {
                location = NSPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
            } else {
                location = NSEvent.mouseLocation
            }
            self.dismissForGlobalClick(at: location)
        }
        // A nonactivating popover also needs dismissal when the foreground app or Space
        // changes without a mouse click.
        self.workspaceDismissalObservers = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
                MainActor.assumeIsolated { self?.popover?.performClose(nil) }
            }
        }
    }

    private func dismissForLocalClick(_ event: NSEvent) {
        guard let window = event.window,
              window !== self.popover?.contentViewController?.view.window,
              window !== self.statusItem?.button?.window,
              window.level.rawValue < NSWindow.Level.popUpMenu.rawValue else { return }
        // Nested menus own their tracking events. Other app windows dismiss the card.
        self.popover?.performClose(nil)
    }

    private func dismissForGlobalClick(at screenLocation: NSPoint) {
        if self.systemManagesStatusItem {
            self.popover?.performClose(nil)
            return
        }
        if let button = self.statusItem?.button, let window = button.window {
            let bounds = window.convertToScreen(button.convert(button.bounds, to: nil))
            if bounds.contains(screenLocation) {
                return
            }
        }
        self.popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) { self.endPresentation() }

    private func stopDismissalMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        self.outsideClickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        self.localClickMonitor = nil
        for observer in self.workspaceDismissalObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.workspaceDismissalObservers = []
    }

    private func endPresentation() {
        self.isMenuOpen = false
        if !self.systemManagesStatusItem { self.statusItem?.button?.state = .off }
        self.stopDismissalMonitoring()
        self.stopOpenMenuClock()
        self.stopRefreshRowClock()
#if canImport(AppKit, _version: 2775)
        if #available(macOS 27, *), self.systemManagesStatusItem {
            self.statusItem?.expandedInterfaceSession?.cancel()
        }
#endif
    }

    private func startOpenMenuClock() {
        self.stopOpenMenuClock()
        let timer = Timer(timeInterval: self.openMenuClockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOpenCard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.openMenuClock = timer
    }
    private func stopOpenMenuClock() {
        self.openMenuClock?.invalidate()
        self.openMenuClock = nil
    }
    private func startRefreshRowClock() {
        self.stopRefreshRowClock()
        let timer = Timer(timeInterval: self.refreshRowClockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRefreshRow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshRowClock = timer
    }
    private func stopRefreshRowClock() {
        self.refreshRowClock?.invalidate()
        self.refreshRowClock = nil
    }

#if DEBUG
    var debugIsPopoverShown: Bool { self.popover?.isShown == true }
    var debugIsStatusItemSelected: Bool { self.statusItem?.button?.state == .on }
    var debugPopoverWindow: NSWindow? { self.popover?.contentViewController?.view.window }
    var debugStatusItemButton: NSStatusBarButton? { self.statusItem?.button }
    func debugDismissForLocalClick(_ event: NSEvent) { self.dismissForLocalClick(event) }
    func debugDismissForGlobalClick(at location: NSPoint) { self.dismissForGlobalClick(at: location) }
    var debugHasMenu: Bool { self.popover != nil }
    private(set) var debugCardUpdateCount = 0
    func debugBeginPresentation() { self.beginPresentation() }
    func debugEndPresentation() { self.endPresentation() }
    func debugStartOpenMenuClock() { self.startOpenMenuClock() }
    func debugStopOpenMenuClock() { self.stopOpenMenuClock() }
    func debugStartRefreshRowClock() { self.startRefreshRowClock() }
    func debugStopRefreshRowClock() { self.stopRefreshRowClock() }
    func debugStatusLine() -> String? { self.presentation?.card.debugStatusLine }
    func debugClickRefreshRow() { self.refreshClicked() }
    func debugRefreshRowState() -> (title: String, trailingText: String?, isEnabled: Bool)? {
        guard let state = self.presentation?.refreshState else { return nil }
        return (state.title, state.trailingText, state.isEnabled)
    }
    func debugShowPopover() { self.showPopover() }
#endif

}

#if canImport(AppKit, _version: 2775)
@available(macOS 27, *)
extension StatusItemController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        self.showPopover()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if self.popover?.isShown == true { self.popover?.performClose(nil) }
    }
}
#endif

/// Handles Escape even before a SwiftUI control has keyboard focus.
@MainActor
private final class MenuPopoverHostingController: NSHostingController<MenuPopoverView> {
    override func cancelOperation(_ sender: Any?) {
        self.rootView.model.onClose()
    }
}
