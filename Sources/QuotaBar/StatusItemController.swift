import QuotaBarCore
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A single `NSStatusItem` showing one provider at a time. Any click opens that provider's card,
/// and the switch at the top of the card is where the provider changes.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let settings: SettingsStore
    private let settingsWindow: SettingsWindowController
    private let now: () -> Date
    private let openMenuClockInterval: TimeInterval
    private let refreshRowClockInterval: TimeInterval
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<MenuCardView>?
    /// Attached to the item only while a click is being handled, so it can be built on the first
    /// open rather than at startup.
    private var menu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    /// Only true between menuWillOpen and menuDidClose: a celebration is claimed when a card is
    /// there to play it, never while the menu is closed.
    private var isMenuOpen = false
    /// The resets the open menu is animating, and the token that replays them. Both are per
    /// provider, so switching providers mid-menu cannot replay the other one's animation.
    private var recoveries: [Provider: [QuotaWindowKind: QuotaRecoveryEvent]] = [:]
    private var celebrationTokens: [Provider: [QuotaWindowKind: Int]] = [:]
    /// "Updated 2m ago" and "Resets in 4h 53m" are strings built at render time, so an open menu
    /// needs its own clock; nothing else publishes between two scheduled refreshes.
    private var openMenuClock: Timer?
    /// The card's clock is too coarse for a per-second countdown, and re-rendering the whole card
    /// once a second to drive one label would be wasteful, so the Refresh row keeps its own.
    private var refreshRowClock: Timer?
    /// Owned by its menu item; held weakly so the row can be relabelled between rebuilt menus.
    private weak var refreshRow: MenuActionRowView?
    /// Whether the cost breakdown is showing a day's full model list. Opening it makes the card
    /// taller, so it lives next to the code that resizes the hosting view. It belongs to one
    /// viewing of the card rather than to the user's settings: every open starts collapsed.
    private var isCostBreakdownExpanded = false
    /// Steps the card's height while the breakdown opens or closes, one display refresh at a
    /// time. Held so a second click can take the sweep over rather than race it.
    private var breakdownLink: CADisplayLink?
    private var breakdownSweep: Sweep?
    /// How far open the list is drawn right now: 0 or 1 at rest, stepped in between by the sweep.
    private var breakdownOpenness: Double = 0
    /// The day whose rows the open card and its off-screen height probe must both measure.
    private var expandedBreakdownDayKey: String?

    /// One reveal, from where the card was to where the click is taking it.
    private struct Sweep {
        let fromHeight: CGFloat
        let toHeight: CGFloat
        let fromOpenness: Double
        let toOpenness: Double
        let began: Date
    }
    /// One autosave name for the one item, so switching providers leaves it where the user
    /// dragged it instead of moving the icon around.
    private static let autosaveName = "quotabar"
    /// The card and the action rows below it are one column.
    private static let cardWidth: CGFloat = 280

    init(
        store: UsageStore,
        settings: SettingsStore,
        pricing: PricingEditorModel,
        now: @escaping () -> Date = { Date() },
        openMenuClockInterval: TimeInterval = 15,
        refreshRowClockInterval: TimeInterval = 1
    ) {
        self.store = store
        self.settings = settings
        self.settingsWindow = SettingsWindowController(settings: settings, pricing: pricing)
        self.now = now
        self.openMenuClockInterval = openMenuClockInterval
        self.refreshRowClockInterval = refreshRowClockInterval
        super.init()

        pricing.onSaved = { [weak store] in store?.refreshCostsAfterPricingChange() }

        // SettingsStore is MainActor-isolated. Consume the emitted provider synchronously so
        // rapid switches cannot leave status-item work queued behind a newer selection.
        self.settings.$menuBarProvider
            .removeDuplicates()
            .sink { [weak self] provider in
                guard let self else { return }
                self.apply(provider: provider, displays: self.store.displays)
            }
            .store(in: &self.cancellables)

        // Cost scanning finishes well after the quota fetch, so both publishers drive a redraw.
        self.store.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displays in self?.apply(displays: displays) }
            .store(in: &self.cancellables)

        self.store.$refreshingProviders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshOpenCard() }
            .store(in: &self.cancellables)
    }

    // MARK: - Status item

    private func apply(provider: Provider? = nil, displays: [Provider: ProviderDisplay]) {
        let active = provider ?? self.settings.menuBarProvider
        let display = displays[active] ?? ProviderDisplay()
        let now = self.now()
        let item = self.materializedStatusItem()
        item.button?.image = Self.icon(for: active, displays: displays, now: now)
        item.button?.toolTip = Self.toolTip(for: active, displays: displays, now: now)
        self.updateCard(provider: active, display: display)
    }

    private func materializedStatusItem() -> NSStatusItem {
        if let existing = self.statusItem { return existing }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.target = self
            button.action = #selector(self.statusItemClicked)
            // Without this the button only ever reports a left-click, and a right-click would do
            // nothing at all instead of opening the menu like every other menu bar item.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
        return item
    }

#if DEBUG
    var debugHasMenu: Bool { self.menu != nil }
    private(set) var debugCardUpdateCount = 0

    func debugStartOpenMenuClock() {
        self.startOpenMenuClock()
    }

    func debugStopOpenMenuClock() {
        self.stopOpenMenuClock()
    }

    func debugStatusLine() -> String? {
        self.hostingView?.rootView.debugStatusLine
    }

    func debugRefreshRowState() -> (title: String, trailingText: String?, isEnabled: Bool)? {
        guard let row = self.refreshRow else { return nil }
        return (row.title, row.trailingText, row.isEnabled)
    }

    func debugClickRefreshRow() {
        guard let row = self.refreshRow, row.isEnabled else { return }
        self.refreshClicked()
    }

    func debugStartRefreshRowClock() {
        self.startRefreshRowClock()
    }

    func debugStopRefreshRowClock() {
        self.stopRefreshRowClock()
    }
#endif

    /// A failed refresh dims the robot but keeps the last good reading's red, so the icon still
    /// carries information. Red is only ever about the provider on show; the badge is the one
    /// thing the icon says about the provider it is not drawing.
    private static func icon(
        for provider: Provider,
        displays: [Provider: ProviderDisplay],
        now: Date
    ) -> NSImage {
        let display = displays[provider] ?? ProviderDisplay()
        let snapshot = display.snapshot
        return IconRenderer.makeIcon(
            hasReading: snapshot?.session != nil || snapshot?.weekly != nil,
            stale: display.isStale,
            otherProviderLow: MenuBarProviderPolicy.otherProviderRunningLow(
                showing: provider,
                snapshots: displays.compactMapValues(\.snapshot),
                now: now
            ),
            runningLow: snapshot.map { MenuBarProviderPolicy.runningLow($0, now: now) } ?? false
        )
    }

    private static func toolTip(
        for provider: Provider,
        displays: [Provider: ProviderDisplay],
        now: Date
    ) -> String {
        let display = displays[provider] ?? ProviderDisplay()
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
        if let error = display.error { parts.append(error) }
        // Both providers wear the same robot, so the tooltip is where the other one is named.
        let others = Self.tightestRemaining(displays, now: now).filter { $0.key != provider }
        for other in Provider.allCases {
            guard let remaining = others[other] else { continue }
            parts.append("\(other.displayName) \(Formatters.percent(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// Each read provider's tightest window, for the card's switch and the tooltip.
    private static func tightestRemaining(
        _ displays: [Provider: ProviderDisplay],
        now: Date
    ) -> [Provider: Double] {
        displays.compactMapValues { display in
            display.snapshot.flatMap { MenuBarProviderPolicy.tightestRemaining($0, now: now) }
        }
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        self.presentMenu()
    }

    /// The menu lives off the item so the button keeps receiving clicks; attaching it for the
    /// duration of one click is how AppKit pops it up below the icon.
    private func presentMenu() {
        guard let item = self.statusItem else { return }
        let menu = self.materializedMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - Menu

    /// Keep SwiftUI view construction and layout out of status-item startup.
    private func materializedMenu() -> NSMenu {
        if let menu = self.menu { return menu }
        let menu = self.makeMenu()
        self.menu = menu
        return menu
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let cardItem = NSMenuItem()
        let hosting = NSHostingView(rootView: self.makeCard(
            provider: self.settings.menuBarProvider,
            display: ProviderDisplay(),
            isRefreshing: false
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200)
        // The card hangs from the top of this view, so while the breakdown is opening the part
        // that has not been uncovered yet has to be cut off rather than drawn over the rows below.
        hosting.clipsToBounds = true
        cardItem.view = hosting
        self.hostingView = hosting
        menu.addItem(cardItem)

        menu.addItem(.separator())

        // Refresh acts on the card the user is already looking at, so it is a custom row: AppKit
        // dismisses a menu the moment a standard item is picked, and putting it back afterwards
        // blinks. A custom row cannot carry a key equivalent — while a menu tracks, AppKit
        // matches ⌘-something against the items itself and skips any item with a view — so the
        // row draws its own trailing content. It is subject to the cooldown, and says so: while
        // that runs the row counts the wait down and refuses clicks, rather than dropping them
        // without a word.
        let refreshItem = NSMenuItem()
        let refreshRow = MenuActionRowView(
            width: Self.cardWidth,
            title: RefreshRowPolicy.idleTitle,
            icon: MenuIcons.symbol("arrow.clockwise"),
            trailingText: nil,
            handler: { [weak self] in self?.refreshClicked() }
        )
        refreshItem.view = refreshRow
        self.refreshRow = refreshRow
        menu.addItem(refreshItem)

        // These two leave the card behind anyway, so they stay standard items and keep working
        // key equivalents.
        let settings = NSMenuItem(
            title: "Settings",
            action: #selector(self.settingsClicked),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        settings.image = MenuIcons.symbol("gearshape")
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.image = MenuIcons.symbol("xmark.rectangle")
        menu.addItem(quit)

        return menu
    }

    /// The card both call sites build. `makeMenu` seeds it with an empty display that the first
    /// `updateCard` overwrites, so the two only ever differ in the data handed in.
    private func makeCard(
        provider: Provider,
        display: ProviderDisplay,
        isRefreshing: Bool? = nil
    ) -> MenuCardView {
        let now = self.now()
        return MenuCardView(
            provider: provider,
            display: display,
            isRefreshing: isRefreshing ?? self.store.isRefreshing(provider),
            recoveries: self.recoveries[provider] ?? [:],
            celebrationTokens: self.celebrationTokens[provider] ?? [:],
            now: now,
            costChartLabelMode: self.settings.costChartLabelMode,
            onCostChartLabelModeChanged: { [weak self] mode in
                self?.settings.costChartLabelMode = mode
            },
            isCostBreakdownExpanded: self.isCostBreakdownExpanded,
            costBreakdownOpenness: self.breakdownOpenness,
            expandedCostBreakdownDayKey: self.expandedBreakdownDayKey,
            onCostBreakdownExpandedChanged: { [weak self] expanded, dayKey in
                self?.setCostBreakdownExpanded(expanded, dayKey: dayKey)
            },
            quotaResetDisplayMode: self.settings.quotaResetDisplayMode,
            onQuotaResetDisplayModeChanged: { [weak self] mode in
                // Both windows read the label the same way, so the click has to redraw the whole
                // card rather than only the row it landed on.
                self?.settings.quotaResetDisplayMode = mode
                self?.refreshOpenCard()
            },
            providerRemaining: Self.tightestRemaining(self.store.displays, now: now),
            onProviderSelected: { [weak self] provider in
                // The icon, the card and the refresh all follow the setting.
                self?.settings.menuBarProvider = provider
            }
        )
    }

    /// A menu has no animation of its own: an item view is resized and AppKit re-lays the menu
    /// out around it, at once. So the card grows and shrinks by hand here, stepped along the same
    /// curve the rows inside it fade on, and the two changes read as one. Without it the only
    /// thing the reader would see of a click is the menu jumping to its new height.
    ///
    /// The height the sweep is heading for is measured on a card of its own rather than read off
    /// the one on screen: letting the live card take the finished height first, even for the one
    /// frame it takes to hand it back, is a frame of the opened card -- which is the jump this
    /// exists to avoid.
    private func setCostBreakdownExpanded(_ expanded: Bool, dayKey: String?) {
        self.isCostBreakdownExpanded = expanded
        if expanded { self.expandedBreakdownDayKey = dayKey }
        self.endBreakdownSweep()
        guard let hosting = self.hostingView else { return }

        let provider = self.settings.menuBarProvider
        let display = self.store.displays[provider] ?? ProviderDisplay()
        let fromHeight = hosting.frame.height
        let fromOpenness = self.breakdownOpenness
        let toOpenness: Double = expanded ? 1 : 0

        // Measured with the card already open the whole way, on a card of its own so the one on
        // screen is not resized to find out.
        self.breakdownOpenness = toOpenness
        let toHeight = self.fittingCardHeight(provider: provider, display: display)

        // Reduce Motion asks for the change, not the sweep that gets there.
        guard !CostChartHoverMotion.systemReduceMotion, abs(toHeight - fromHeight) >= 1 else {
            if !expanded { self.expandedBreakdownDayKey = nil }
            self.refreshOpenCard()
            self.setCardHeight(toHeight)
            return
        }

        self.breakdownSweep = Sweep(
            fromHeight: fromHeight,
            toHeight: toHeight,
            fromOpenness: fromOpenness,
            toOpenness: toOpenness,
            began: Date()
        )
        self.breakdownOpenness = fromOpenness
        self.refreshOpenCard()
        self.setCardHeight(fromHeight)
        // One step per display refresh, rather than a timer that can land twice in a frame or
        // miss one: the menu re-lays itself out on every step, and an uneven step reads as the
        // card stuttering rather than opening.
        let link = hosting.displayLink(target: self, selector: #selector(self.stepBreakdownSweep))
        link.add(to: .main, forMode: .common)
        self.breakdownLink = link
    }

    /// What the card would be if it were laid out right now, measured on a card of its own so the
    /// one on screen is not resized to find out.
    private func fittingCardHeight(provider: Provider, display: ProviderDisplay) -> CGFloat {
        let probe = NSHostingView(rootView: self.makeCard(provider: provider, display: display))
        probe.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: 0)
        return probe.fittingSize.height
    }

    @objc private func stepBreakdownSweep() {
        guard let sweep = self.breakdownSweep else {
            self.endBreakdownSweep()
            return
        }
        let elapsed = Date().timeIntervalSince(sweep.began)
        let progress = min(1, elapsed / CostChartHoverMotion.breakdownDuration)
        let eased = CostChartHoverMotion.breakdownEase(progress)
        // Height and rows off the same reading, so the card's edge and the lines inside it cannot
        // drift apart -- and both land on whole points, where text does not shimmer.
        self.breakdownOpenness = sweep.fromOpenness + (sweep.toOpenness - sweep.fromOpenness) * eased
        self.refreshOpenCard()
        self.setCardHeight(CostChartHoverMotion.breakdownHeight(
            start: sweep.fromHeight,
            target: sweep.toHeight,
            progress: progress
        ))
        guard progress >= 1 else { return }
        self.breakdownOpenness = sweep.toOpenness
        self.endBreakdownSweep()
        if sweep.toOpenness == 0 { self.expandedBreakdownDayKey = nil }
        self.refreshOpenCard()
        // The measured target and what the finished card actually wants agree to a rounding, but
        // the landing is taken from the card itself so the two cannot drift apart.
        if let height = self.hostingView?.fittingSize.height { self.setCardHeight(height) }
    }

    private func endBreakdownSweep() {
        self.breakdownLink?.invalidate()
        self.breakdownLink = nil
        self.breakdownSweep = nil
    }

    /// Whole points, always: the card is laid out from the top edge of this view, so a height with
    /// a fraction in it puts every line on the card on a fraction of a pixel. Rounded up rather
    /// than to nearest, so the last line is never half a point short of its own descenders.
    private func setCardHeight(_ height: CGFloat) {
        self.hostingView?.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.cardWidth,
            height: height.rounded(.up)
        )
    }

    private func updateCard(provider: Provider, display: ProviderDisplay) {
        guard self.isMenuOpen, let hosting = self.hostingView else { return }
#if DEBUG
        self.debugCardUpdateCount += 1
#endif
        // A window can come back while the menu is already open, so this is claimed on every
        // update rather than only when the menu is opened.
        self.claimCelebrations(for: provider)
        let before = Self.openMenuGeometry(hosting)
        hosting.rootView = self.makeCard(provider: provider, display: display)
        // The card's height depends on how many windows the provider reported, so resize to fit.
        // A card mid-open owns its own height until the sweep lands on it; a refresh arriving in
        // those few frames would snap the menu to the finished height and cut the animation short.
        guard self.breakdownSweep == nil else { return }
        self.setCardHeight(hosting.fittingSize.height)
        Self.movePointerWithRows(from: before, hosting: hosting)
    }

    /// Takes whatever this provider has waiting and bumps its token, which is the value change
    /// the bars watch. Already-claimed windows keep the same token, so redrawing the open card
    /// does not restart an animation halfway through.
    private func claimCelebrations(for provider: Provider) {
        guard self.isMenuOpen else { return }
        let events = self.store.consumeCelebrations(for: provider)
        guard !events.isEmpty else { return }
        self.recoveries[provider, default: [:]].merge(events) { _, newest in newest }
        for kind in events.keys {
            self.celebrationTokens[provider, default: [:]][kind, default: 0] += 1
        }
    }

    /// The card's bottom edge and the menu's frame, both in screen coordinates. nil when no menu
    /// is on screen, which is every update the user is not looking at.
    private static func openMenuGeometry(
        _ hosting: NSHostingView<MenuCardView>
    ) -> (cardBottom: CGFloat, menuFrame: CGRect)? {
        guard let window = hosting.window else { return nil }
        let inWindow = hosting.convert(hosting.bounds, to: nil)
        let bottom = window.convertPoint(toScreen: NSPoint(x: inWindow.minX, y: inWindow.minY))
        return (bottom.y, window.frame)
    }

    /// Keeps the pointer on the row it is pointing at across a card resize. AppKit re-lays an open
    /// menu out as soon as the card's frame changes, so the rows below it have already moved.
    private static func movePointerWithRows(
        from before: (cardBottom: CGFloat, menuFrame: CGRect)?,
        hosting: NSHostingView<MenuCardView>
    ) {
        guard let before else { return }
        hosting.window?.contentView?.layoutSubtreeIfNeeded()
        guard let after = Self.openMenuGeometry(hosting),
              let destination = MenuPointerFollowPolicy.pointerDestination(
                  pointer: NSEvent.mouseLocation,
                  menuFrameBefore: before.menuFrame,
                  cardBottomBefore: before.cardBottom,
                  cardBottomAfter: after.cardBottom
              ),
              // Core Graphics measures from the top of the primary display, AppKit from its bottom.
              let primary = NSScreen.screens.first
        else { return }
        CGWarpMouseCursorPosition(CGPoint(
            x: destination.x,
            y: primary.frame.maxY - destination.y
        ))
    }

    private func refreshOpenCard() {
        guard self.isMenuOpen else { return }
        let provider = self.settings.menuBarProvider
        self.updateCard(provider: provider, display: self.store.displays[provider] ?? ProviderDisplay())
        self.updateRefreshRow()
    }

    /// Ordinary clicks respect the API cooldown. A recovery-required row is the user's explicit
    /// authorization for Claude Code to repair its own credentials, so that one click is forced.
    private func refreshClicked() {
        let provider = self.settings.menuBarProvider
        let isCredentialRecovery = self.store.displays[provider]?.canAttemptCredentialRecovery == true
        self.store.refresh(force: isCredentialRecovery, interaction: .userInitiated)
        self.updateRefreshRow()
    }

    private func updateRefreshRow() {
        guard let row = self.refreshRow else { return }
        let state = RefreshRowPolicy.state(
            cooldownRemaining: self.store.refreshCooldownRemaining(),
            isRefreshing: self.store.isRefreshing(self.settings.menuBarProvider),
            allowsCredentialRecovery: self.store.displays[self.settings.menuBarProvider]?
                .canAttemptCredentialRecovery == true
        )
        row.title = state.title
        row.trailingText = state.trailingText
        row.isEnabled = state.isEnabled
    }

    @objc private func settingsClicked() {
        self.settingsWindow.show()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_: NSMenu) {
        _ = self.materializedMenu()
        // Opening the menu asks for a refresh; the store's cooldown decides. Within a minute of
        // any earlier refresh, poll or click alike, the open reuses that result.
        self.store.refresh()
        self.isMenuOpen = true
        // A celebration belongs to one viewing of the card. Whatever the last one played is over.
        self.recoveries = [:]
        // So does an opened breakdown: the card comes back at the height it was designed for.
        self.isCostBreakdownExpanded = false
        self.breakdownOpenness = 0
        self.expandedBreakdownDayKey = nil
        self.refreshOpenCard()
        self.startOpenMenuClock()
        self.startRefreshRowClock()
    }

    func menuDidClose(_: NSMenu) {
        self.isMenuOpen = false
        self.endBreakdownSweep()
        self.stopOpenMenuClock()
        self.stopRefreshRowClock()
    }

    private func startOpenMenuClock() {
        self.stopOpenMenuClock()
        let timer = Timer(timeInterval: self.openMenuClockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOpenCard() }
        }
        // Menu tracking runs the run loop in its own mode, so the default mode would never fire.
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
        // Menu tracking runs the run loop in its own mode, so the default mode would never fire.
        RunLoop.main.add(timer, forMode: .common)
        self.refreshRowClock = timer
    }

    private func stopRefreshRowClock() {
        self.refreshRowClock?.invalidate()
        self.refreshRowClock = nil
    }
}
