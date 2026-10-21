@testable import QuotaBarApp
import AppKit

/// Checks event ordering without activating apps or posting input to the desktop.
@MainActor
enum PopoverInputActivationTests {
    static func run() async {
        await AppCheck.run("popover input activation") {
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
            func didActivate() {
                center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            }
            let down = try Self.mouse(.leftMouseDown)
            let drag = try Self.mouse(.leftMouseDragged)
            let up = try Self.mouse(.leftMouseUp)
            let escape = try Self.key(.keyDown, code: 53, characters: "\u{1b}")

            try AppCheck.require(input.handle(up) === up, "an unmatched release was delayed")
            try AppCheck.require(input.handle(escape) === escape, "Escape was delayed instead of closing the glance")
            try AppCheck.require(activations == 0, "a release or Escape activated the app")
            frontmost = true
            try AppCheck.require(input.handle(down) === down, "frontmost input was delayed")
            try AppCheck.require(activations == 0, "frontmost input requested redundant activation")

            frontmost = false
            try AppCheck.require(input.handle(down) == nil, "the first press reached a control before activation")
            try AppCheck.require(input.handle(drag) == nil && input.handle(up) == nil, "the press lost its drag or release")
            try AppCheck.require(activations == 1, "one interaction requested activation more than once")
            didActivate()
            try AppCheck.require(posted.isEmpty, "an incomplete foreground handoff replayed input")
            frontmost = true
            didActivate()
            try AppCheck.require(posted.count == 3 && posted[0] === down && posted[1] === drag && posted[2] === up,
                                 "activation reordered or duplicated the original mouse events")
            for event in posted {
                try AppCheck.require(input.handle(event) === event, "replayed input started another activation")
            }
            didActivate()
            try AppCheck.require(posted.count == 3, "a later notification replayed the click twice")

            posted = []
            frontmost = false
            try AppCheck.require(input.handle(down) == nil, "a later presentation bypassed activation")
            try AppCheck.require(input.handle(up) == nil, "a queued press lost its release")
            try AppCheck.require(input.handle(escape) === escape, "Escape could not cancel a pending activation")
            input.cancel()
            frontmost = true
            didActivate()
            try AppCheck.require(posted.isEmpty, "closing the popover replayed stale input after activation")

            let clickTypes: [[NSEvent.EventType]] = [[.rightMouseDown, .rightMouseUp], [.otherMouseDown, .otherMouseUp]]
            for types in clickTypes {
                posted = []
                frontmost = false
                let press = try Self.mouse(types[0])
                let release = try Self.mouse(types[1])
                try AppCheck.require(input.handle(press) == nil && input.handle(release) == nil,
                                     "a non-left click bypassed activation")
                frontmost = true
                didActivate()
                try AppCheck.require(posted.count == 2 && posted[0] === press && posted[1] === release,
                                     "a non-left click lost its original events")
            }

            posted = []
            frontmost = false
            let keyDown = try Self.key(.keyDown, code: 49, characters: " ")
            let keyUp = try Self.key(.keyUp, code: 49, characters: " ")
            try AppCheck.require(input.handle(keyDown) == nil && input.handle(keyUp) == nil,
                                 "keyboard activation reached a menu before the app was ready")
            frontmost = true
            didActivate()
            try AppCheck.require(posted.count == 2 && posted[0] === keyDown && posted[1] === keyUp,
                                 "keyboard activation lost its press or release")
        }
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 12, y: 18), modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ) else { throw CheckFailure(description: "could not construct mouse input") }
        return event
    }

    private static func key(_ type: NSEvent.EventType, code: UInt16, characters: String) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else { throw CheckFailure(description: "could not construct keyboard input") }
        return event
    }
}
