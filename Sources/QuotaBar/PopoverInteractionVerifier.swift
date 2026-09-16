#if DEBUG
import AppKit
import QuotaBarCore
import SwiftUI

/// Exercises AppKit's real menu command route and the popover's capped layout with fixtures.
@MainActor
enum PopoverInteractionVerifier {
    private static let suite = "QuotaBarPopoverInteractionVerifier"
    private static let positionTolerance: CGFloat = 0.75

    private struct LayoutSample {
        let headline: CGPoint
        let reset: CGPoint
        let popoverWidth: CGFloat
        let popoverHeight: CGFloat
        let contentHeight: CGFloat
    }

    @MainActor
    private final class Requests {
        var quota = 0

        func fetch(_ provider: Provider) async -> ProviderState {
            self.quota += 1
            return .loaded(CardDump.loadedSnapshot(provider))
        }
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { await Self.verify() }
        RunLoop.main.run()
        fatalError("popover interaction verification run loop stopped")
    }

    private static func verify() async -> Never {
        guard UserDefaults(suiteName: Self.suite) != nil else {
            VerifierReport.report("could not isolate preferences", label: "popover interaction verification")
            exit(2)
        }
        let defaults = EphemeralDefaults.make(Self.suite)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarPopoverInteraction-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return Self.finish("could not create fixture directory: \(error)", scratch: scratch)
        }
        func require(_ condition: Bool, _ message: String) {
            if !condition { Self.finish(message, scratch: scratch) }
        }

        let settings = SettingsStore(defaults: defaults)
        settings.refreshFrequency = .manual
        settings.menuBarProvider = .codex
        let service = CostService(pricingOverlay: PricingOverlay())
        let requests = Requests()
        var uptime: TimeInterval = 1_000
        let store = UsageStore(
            settings: settings,
            costService: service,
            clock: { uptime },
            fetchState: { provider, _ in await requests.fetch(provider) },
            fetchCost: { provider in CardDump.busyCost(provider) },
            historyStore: UsageHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            recoveryDefaults: defaults
        )
        let pricing = PricingEditorModel(
            costService: service,
            fixtures: .init(usage: [:], overlay: PricingOverlay()),
            saveOperations: .init(freeze: {}, write: { _ in }, invalidate: {})
        )
        let controller = StatusItemController(store: store, settings: settings, pricing: pricing)
        controller.installApplicationMenu()

        guard let menu = NSApp.mainMenu,
              let commands = menu.items.first?.submenu,
              let refreshItem = commands.item(withTitle: "Refresh"),
              let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ) else {
            return Self.finish("the native Refresh key equivalent was unavailable", scratch: scratch)
        }

        commands.update()
        require(refreshItem.isEnabled, "the Refresh command started disabled")
        require(menu.performKeyEquivalent(with: key), "Cmd-R did not reach the application menu")
        require(await Self.wait(until: { requests.quota == 1 && !store.isRefreshing(.codex) }),
                "Cmd-R did not complete one fixture request")

        commands.update()
        require(!refreshItem.isEnabled, "the Refresh command ignored its cooldown validation")
        _ = menu.performKeyEquivalent(with: key)
        await Task.yield()
        require(requests.quota == 1, "Cmd-R bypassed the refresh cooldown")

        uptime = 1_061
        commands.update()
        require(refreshItem.isEnabled, "the Refresh command did not re-enable after cooldown")
        require(menu.performKeyEquivalent(with: key), "Cmd-R remained disabled after cooldown")
        require(await Self.wait(until: { requests.quota == 2 && !store.isRefreshing(.codex) }),
                "Cmd-R did not run after cooldown")

        // A dense fixture must scroll inside the content viewport while actions stay below it.
        store.debugSetDisplay(ProviderDisplay(
            snapshot: CardDump.loadedSnapshot(.codex), cost: CardDump.busyCost(.codex)
        ), for: .codex)
        controller.debugShowPopover()
        RunLoopDrain.run(for: 0.15)
        guard let popover = controller.debugPopover,
              let hosting = popover.contentViewController as? NSHostingController<MenuPopoverView> else {
            return Self.finish("the native popover did not open", scratch: scratch)
        }
        let model = hosting.rootView.model

        // Press the controls exposed by the live hosting view, then measure its AppKit layout.
        model.maximumHeight = 700
        model.onSizeChanged()
        RunLoopDrain.run(for: 0.05)
        require(await Self.wait(until: { model.contentHeight > 0 }),
                "the open popover did not measure its card")
        guard let baseline = Self.sample(popover: popover, hosting: hosting, model: model) else {
            return Self.finish("the open popover exposed no headline/reset layout probes", scratch: scratch)
        }
        func requireStable(_ label: String, against reference: LayoutSample = baseline) {
            guard let current = Self.sample(popover: popover, hosting: hosting, model: model) else {
                Self.finish("\(label): the live layout probes disappeared", scratch: scratch)
            }
            require(Self.near(current.headline, reference.headline),
                    "\(label): the headline moved relative to the hosting view's top-left")
            require(Self.near(current.reset, reference.reset),
                    "\(label): the reset label moved relative to the hosting view's top-left")
            require(abs(current.popoverWidth - 280) <= 0.5,
                    "\(label): the native popover changed width")
        }
        require(abs(baseline.popoverWidth - 280) <= 0.5, "the native popover started at the wrong width")

        for cycle in 1...3 {
            require(Self.pressProbe("pace-disclosure", in: hosting.view),
                    "pace cycle \(cycle): the live disclosure did not receive a mouse click")
            require(await Self.wait(until: { model.contentHeight > baseline.contentHeight + 30 }),
                    "pace cycle \(cycle): expanding did not add real content")
            for delay in [0.01, 0.04, 0.10, 0.18, 0.32] {
                RunLoopDrain.run(for: delay)
                requireStable("pace cycle \(cycle) expanded at \(delay)s")
            }
            require(Self.pressProbe("pace-disclosure", in: hosting.view),
                    "pace cycle \(cycle): the live disclosure could not collapse")
            require(await Self.wait(until: { abs(model.contentHeight - baseline.contentHeight) <= 1 }),
                    "pace cycle \(cycle): collapsing did not remove the detail content")
            for delay in [0.01, 0.04, 0.10, 0.18, 0.32] {
                RunLoopDrain.run(for: delay)
                requireStable("pace cycle \(cycle) collapsed at \(delay)s")
            }
        }

        for click in 1...8 {
            require(Self.pressProbe("pace-disclosure", in: hosting.view),
                    "rapid pace click \(click): the live disclosure did not receive a mouse click")
            RunLoopDrain.run(for: 0.04)
            requireStable("rapid pace click \(click)")
            require(click.isMultiple(of: 2)
                    ? abs(model.contentHeight - baseline.contentHeight) <= 1
                    : model.contentHeight > baseline.contentHeight + 30,
                    "rapid pace click \(click): the card height did not follow the click")
        }
        require(await Self.wait(until: { abs(model.contentHeight - baseline.contentHeight) <= 1 }),
                "rapid pace clicks did not restore the collapsed card height")
        requireStable("rapid pace clicks settled")

        guard let modeBaseline = Self.sample(popover: popover, hosting: hosting, model: model) else {
            return Self.finish("the mode switch lost its layout probes", scratch: scratch)
        }
        for cycle in 1...3 {
            for mode in [CostChartLabelMode.cost, .tokens] {
                let label = mode == .cost ? "Cost" : "Tokens"
                require(Self.press(label: label, in: hosting.view),
                        "mode cycle \(cycle): the \(label) segment was not pressable")
                require(await Self.wait(until: { settings.costChartLabelMode == mode }),
                        "mode cycle \(cycle): the \(label) segment did not change the saved mode")
                for delay in [0.01, 0.04, 0.10, 0.18, 0.35] {
                    RunLoopDrain.run(for: delay)
                    let context = "mode cycle \(cycle) \(label) at \(delay)s"
                    requireStable(context, against: modeBaseline)
                    guard let current = Self.sample(popover: popover, hosting: hosting, model: model) else {
                        return Self.finish("\(context): layout probes disappeared", scratch: scratch)
                    }
                    require(abs(current.contentHeight - modeBaseline.contentHeight) <= 1,
                            "\(context): the card height changed")
                    require(abs(current.popoverHeight - modeBaseline.popoverHeight) <= 1,
                            "\(context): the popover height changed")
                }
            }
        }

        // Reopening an expanded card must start at its collapsed size, without a visible
        // second resize. Exercise the status button's installed action in both directions.
        require(Self.pressProbe("pace-disclosure", in: hosting.view),
                "reopen setup: the pace disclosure could not expand")
        require(await Self.wait(until: { model.contentHeight > baseline.contentHeight + 30 }),
                "reopen setup: the card did not expand")
        guard let statusButton = controller.debugStatusButton else {
            return Self.finish("the status item has no button", scratch: scratch)
        }
        for cycle in 1...4 {
            let rightMouse = cycle.isMultiple(of: 2)
            require(Self.clickStatusButton(statusButton, rightMouse: rightMouse),
                    "status click \(cycle): the mouse events could not be created")
            require(!popover.isShown, "status click \(cycle): the popover did not close")
            RunLoopDrain.run(for: 0.02)
            require(!popover.isShown, "status click \(cycle): mouse-up reopened the popover")
            require(Self.clickStatusButton(statusButton, rightMouse: rightMouse),
                    "status reopen \(cycle): the mouse events could not be created")
            require(popover.isShown, "status click \(cycle): the popover did not reopen")
            require(abs(model.contentHeight - baseline.contentHeight) <= 1,
                    "reopen \(cycle): the first frame retained the expanded height")
            require(abs(popover.contentSize.height - (model.viewportHeight + model.footerHeight)) <= 1,
                    "reopen \(cycle): the native popover retained its previous height")
            RunLoopDrain.run(for: 0.04)
            require(popover.isShown, "status reopen \(cycle): mouse-up closed the popover")
            requireStable("reopen \(cycle)")
        }

        model.maximumHeight = 220
        model.onSizeChanged()
        RunLoopDrain.run(for: 0.05)
        require(model.contentHeight > model.viewportHeight, "the dense card did not require scrolling")
        require(popover.contentSize.width == 280 && popover.contentSize.height <= 220,
                "the popover exceeded its capped 280 pt viewport")
        require(model.footerHeight == 85 && model.viewportHeight <= 135,
                "the action footer did not retain space below the scroll viewport")

        // Calling the card action checks saved-mode updates while the popover stays open.
        // It does not exercise SwiftUI's native Menu tracking or a real desktop click.
        for cycle in 1...3 {
            require(popover.isShown && controller.debugDismissalMonitorCount == 2,
                    "dismissal cycle \(cycle): the open popover lacks a dismissal monitor")
            let mode: QuotaResetDisplayMode = cycle.isMultiple(of: 2) ? .countdown : .clock
            model.card.onQuotaResetDisplayModeChanged(mode)
            require(await Self.wait(until: {
                settings.quotaResetDisplayMode == mode && model.card.quotaResetDisplayMode == mode
            }), "dismissal cycle \(cycle): the reset display mode did not update")
            require(popover.isShown && controller.debugDismissalMonitorCount == 2,
                    "dismissal cycle \(cycle): changing reset mode closed the popover or lost a monitor")

            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            require(await Self.wait(until: {
                !popover.isShown && controller.debugDismissalMonitorCount == 0
            }), "dismissal cycle \(cycle): app deactivation did not close and clean up the popover")

            controller.debugShowPopover()
            require(await Self.wait(until: { popover.isShown && controller.debugDismissalMonitorCount == 2 }),
                    "dismissal cycle \(cycle): reopening did not restore dismissal monitors")
        }

        // A quota reset must keep the pace disclosure available even when the weekly window
        // has only just started and there is no limited session or history to fall back on.
        model.maximumHeight = 700
        model.onSizeChanged()
        let resetNow = Date()
        let resetSnapshot = UsageSnapshot(
            provider: .codex,
            session: nil,
            weekly: UsageWindow(
                usedPercent: 1,
                resetsAt: resetNow.addingTimeInterval(6 * 86_400 + 23 * 3_600),
                windowSeconds: 604_800
            ),
            planLabel: "Pro",
            credits: nil,
            fetchedAt: resetNow,
            sessionIsUnlimited: true
        )
        store.debugSetDisplay(ProviderDisplay(snapshot: resetSnapshot), for: .codex)
        require(await Self.wait(until: {
            model.card.display.snapshot == resetSnapshot && model.contentHeight < baseline.contentHeight
        }), "quota reset: the open popover did not replace its previous usage")
        RunLoopDrain.run(for: 0.05)
        let resetCollapsedHeight = model.contentHeight
        require(Self.pressProbe("pace-disclosure", in: hosting.view),
                "quota reset: the weekly pace disclosure disappeared")
        require(await Self.wait(until: { model.contentHeight > resetCollapsedHeight + 30 }),
                "quota reset: expanding did not reveal actual pace details")
        require(Self.clickStatusButton(statusButton, rightMouse: false),
                "quota reset: the status button could not close the expanded card")
        require(!popover.isShown, "quota reset: the expanded card did not close")
        require(Self.clickStatusButton(statusButton, rightMouse: false),
                "quota reset: the status button could not reopen the card")
        require(await Self.wait(until: {
            popover.isShown && abs(model.contentHeight - resetCollapsedHeight) <= 1
        }), "quota reset: reopening did not restore the collapsed card")
        require(Self.pressProbe("pace-disclosure", in: hosting.view),
                "quota reset: the pace disclosure disappeared after reopening")
        require(await Self.wait(until: { model.contentHeight > resetCollapsedHeight + 30 }),
                "quota reset: the reopened card could not expand its pace details")

        popover.performClose(nil)
        require(await Self.wait(until: { controller.debugDismissalMonitorCount == 0 }),
                "final close retained dismissal monitors")
        store.stop()
        withExtendedLifetime(controller) {}
        Self.finish(nil, scratch: scratch)
    }

    private static func wait(until ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return ready()
    }

    private static func finish(_ failure: String?, scratch: URL) -> Never {
        EphemeralDefaults.clear(Self.suite)
        try? FileManager.default.removeItem(at: scratch)
        if let failure {
            VerifierReport.report(failure, label: "popover interaction verification")
            exit(1)
        }
        print("Native Cmd-R, disclosure, quota reset, unit switching, capped layout, and dismissal lifecycle checks passed")
        exit(0)
    }

    private static func sample(
        popover: NSPopover,
        hosting: NSHostingController<MenuPopoverView>,
        model: MenuPopoverModel
    ) -> LayoutSample? {
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        let probes = Self.layoutProbes(in: view)
        guard let headline = probes.first(where: { $0.probeIdentifier == "headline" }),
              let reset = probes.first(where: { $0.probeIdentifier == "reset" }) else { return nil }
        func topLeft(of probe: QuotaLayoutProbeView) -> CGPoint {
            let frame = probe.convert(probe.bounds, to: view)
            return CGPoint(x: frame.minX, y: view.isFlipped ? frame.minY : view.bounds.maxY - frame.maxY)
        }
        return LayoutSample(
            headline: topLeft(of: headline), reset: topLeft(of: reset),
            popoverWidth: popover.contentSize.width, popoverHeight: popover.contentSize.height,
            contentHeight: model.contentHeight
        )
    }

    private static func layoutProbes(in view: NSView) -> [QuotaLayoutProbeView] {
        view.subviews.flatMap { subview in
            let own = subview as? QuotaLayoutProbeView
            return (own.map { [$0] } ?? []) + Self.layoutProbes(in: subview)
        }
    }

    private static func near(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= Self.positionTolerance
            && abs(lhs.y - rhs.y) <= Self.positionTolerance
    }

    private static func pressProbe(_ identifier: String, in view: NSView) -> Bool {
        guard let probe = Self.layoutProbes(in: view).first(where: { $0.probeIdentifier == identifier }),
              let window = view.window else { return false }
        let frame = probe.convert(probe.bounds, to: nil)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    /// Queue mouse-up before entering AppKit's button tracking loop. Events stay inside this
    /// fixture application's queue and exercise the installed mouse-down action mask.
    private static func clickStatusButton(_ button: NSStatusBarButton, rightMouse: Bool) -> Bool {
        guard let window = button.window else { return false }
        let frame = button.convert(button.bounds, to: nil)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = NSEvent.mouseEvent(
            with: rightMouse ? .rightMouseDown : .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: rightMouse ? .rightMouseUp : .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) else { return false }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        // Some buttons return on mouse-down; others consume mouse-up while tracking.
        // Deliver an unconsumed release once, just as NSApplication's event loop would.
        if let release = NSApp.nextEvent(
            matching: rightMouse ? .rightMouseUp : .leftMouseUp,
            until: Date(), inMode: .default, dequeue: true
        ) {
            window.sendEvent(release)
        }
        return true
    }

    private static func press(label: String, in view: NSView) -> Bool {
        Self.accessibilityElements(in: view).contains { element in
            guard Self.label(of: element) == label else { return false }
            guard element.accessibilityActionNames().contains(.press) else { return false }
            element.accessibilityPerformAction(.press)
            return true
        }
    }

    private static func label(of element: NSObject) -> String? {
        let candidates = [
            element.accessibilityAttributeValue(.title) as? String,
            element.accessibilityAttributeValue(.description) as? String,
            (element as? any NSAccessibilityProtocol)?.accessibilityLabel()
        ]
        return candidates.compactMap { $0 }.first(where: { !$0.isEmpty })
    }

    private static func accessibilityElements(in view: NSView) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        var result: [NSObject] = []
        func visit(_ object: Any, depth: Int) {
            guard depth < 40, let element = object as? NSObject else { return }
            let identity = ObjectIdentifier(element)
            guard visited.insert(identity).inserted else { return }
            result.append(element)
            let children = (element.accessibilityAttributeValue(.children) as? [Any])
                ?? (element as? any NSAccessibilityProtocol)?.accessibilityChildren()
                ?? []
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(view, depth: 0)
        return result
    }
}
#endif
