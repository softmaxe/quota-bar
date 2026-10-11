import AppKit

/// Delays the first control interaction until AppKit finishes activating the app.
@MainActor
final class PopoverInputActivation {
    private let notificationCenter: NotificationCenter
    private let isFrontmost: @MainActor () -> Bool
    private let activate: @MainActor () -> Void
    private let postEvent: @MainActor (NSEvent) -> Void
    private var activationObserver: NSObjectProtocol?
    private var pendingEvents: [NSEvent] = []

    static let eventMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .keyDown, .keyUp
    ]

    init(notificationCenter: NotificationCenter = .default,
         isFrontmost: @escaping @MainActor () -> Bool = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
         },
         activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         postEvent: @escaping @MainActor (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }) {
        self.notificationCenter = notificationCenter
        self.isFrontmost = isFrontmost
        self.activate = activate
        self.postEvent = postEvent
    }

    deinit {
        if let activationObserver { self.notificationCenter.removeObserver(activationObserver) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        // Escape must still close a glance without activating the app.
        if event.type == .keyDown, event.keyCode == 53 { return event }
        if self.activationObserver != nil {
            self.pendingEvents.append(event)
            return nil
        }
        let startsInteraction = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type)
        guard startsInteraction, !self.isFrontmost() else { return event }
        self.pendingEvents = [event]
        self.activationObserver = self.notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didActivate() }
        }
        // A status-item session can report NSApp.isActive before the app is actually
        // frontmost. activate() alone then does nothing on macOS 27.
        self.activate()
        return nil
    }

    func cancel() {
        if let activationObserver { self.notificationCenter.removeObserver(activationObserver) }
        self.activationObserver = nil
        self.pendingEvents = []
    }

    private func didActivate() {
        // Ignore activation notifications that do not complete the foreground handoff.
        guard self.isFrontmost() else { return }
        let events = self.pendingEvents
        self.cancel()
        // Prepend in reverse order so the original press precedes its release and any
        // events still waiting in AppKit's queue. Do not enter menu tracking here.
        for event in events.reversed() { self.postEvent(event) }
    }
}
