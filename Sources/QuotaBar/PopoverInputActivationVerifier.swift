#if DEBUG
import AppKit

/// Checks event ordering without activating apps or posting input to the desktop.
@MainActor
enum PopoverInputActivationVerifier {
    static func run() {
        let center = NotificationCenter()
        var frontmost = false
        var activations = 0
        var posted: [NSEvent] = []
        let input = PopoverInputActivation(
            notificationCenter: center,
            isFrontmost: { frontmost },
            activate: { activations += 1 },
            postEvent: { posted.insert($0, at: 0) }
        )
        func require(_ condition: Bool, _ message: String) {
            VerifierReport.require(condition, message, label: "popover-input-activation verification")
        }
        func didActivate() {
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        let down = self.mouse(.leftMouseDown)
        let drag = self.mouse(.leftMouseDragged)
        let up = self.mouse(.leftMouseUp)
        let escape = self.key(.keyDown, code: 53, characters: "\u{1b}")

        require(input.handle(up) === up, "an unmatched release was delayed")
        require(input.handle(escape) === escape, "Escape was delayed instead of closing the glance")
        require(activations == 0, "a release or Escape activated the app")
        frontmost = true
        require(input.handle(down) === down, "frontmost input was delayed")
        require(activations == 0, "frontmost input requested redundant activation")

        frontmost = false
        require(input.handle(down) == nil, "the first press reached a control before activation")
        require(input.handle(drag) == nil && input.handle(up) == nil, "the press lost its drag or release")
        require(activations == 1, "one interaction requested activation more than once")
        didActivate()
        require(posted.isEmpty, "an incomplete foreground handoff replayed input")
        frontmost = true
        didActivate()
        require(posted.count == 3 && posted[0] === down && posted[1] === drag && posted[2] === up,
                "activation reordered or duplicated the original mouse events")
        for event in posted {
            require(input.handle(event) === event, "replayed input started another activation")
        }
        didActivate()
        require(posted.count == 3, "a later notification replayed the click twice")

        posted = []
        frontmost = false
        require(input.handle(down) == nil, "a later presentation bypassed activation")
        require(input.handle(up) == nil, "a queued press lost its release")
        require(input.handle(escape) === escape, "Escape could not cancel a pending activation")
        input.cancel()
        frontmost = true
        didActivate()
        require(posted.isEmpty, "closing the popover replayed stale input after activation")

        let clickTypes: [[NSEvent.EventType]] = [[.rightMouseDown, .rightMouseUp], [.otherMouseDown, .otherMouseUp]]
        for types in clickTypes {
            posted = []
            frontmost = false
            let press = self.mouse(types[0])
            let release = self.mouse(types[1])
            require(input.handle(press) == nil && input.handle(release) == nil,
                    "a non-left click bypassed activation")
            frontmost = true
            didActivate()
            require(posted.count == 2 && posted[0] === press && posted[1] === release,
                    "a non-left click lost its original events")
        }

        posted = []
        frontmost = false
        let keyDown = self.key(.keyDown, code: 49, characters: " ")
        let keyUp = self.key(.keyUp, code: 49, characters: " ")
        require(input.handle(keyDown) == nil && input.handle(keyUp) == nil,
                "keyboard activation reached a menu before the app was ready")
        frontmost = true
        didActivate()
        require(posted.count == 2 && posted[0] === keyDown && posted[1] === keyUp,
                "keyboard activation lost its press or release")
        print("Popover input waits for activation, preserves event order, and cancels on close")
    }

    private static func mouse(_ type: NSEvent.EventType) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 12, y: 18), modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ) else {
            VerifierReport.fail("could not construct mouse input", label: "popover-input-activation verification")
        }
        return event
    }

    private static func key(_ type: NSEvent.EventType, code: UInt16, characters: String) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else {
            VerifierReport.fail("could not construct keyboard input", label: "popover-input-activation verification")
        }
        return event
    }
}
#endif
