import SwiftUI

/// Custom controls acknowledge a press immediately without moving their labels or hit targets.
struct ControlFeedbackStyle: ButtonStyle {
    static let pressedOpacity = 0.72
    static let releaseDuration = 0.10
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = self.isEnabled && configuration.isPressed
        configuration.label
            .opacity(pressed ? Self.pressedOpacity : 1)
            .animation(
                pressed || self.reduceMotion || self.systemReduceMotion || !self.isEnabled
                    ? nil : .easeOut(duration: Self.releaseDuration),
                value: pressed
            )
    }
}
