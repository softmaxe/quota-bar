import SwiftUI

/// Custom controls acknowledge a press immediately: the label dims and squishes slightly, then
/// springs back on release. The squish is drawn only, so the hit target and the surrounding
/// layout never move.
struct ControlFeedbackStyle: ButtonStyle {
    static let pressedOpacity = 0.72
    static let releaseDuration = 0.10
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var reduceMotion = false
    /// 1 for controls whose drawing carries a quantity, such as chart bars.
    var pressScale = CardMotion.pressScale

    func makeBody(configuration: Configuration) -> some View {
        let pressed = self.isEnabled && configuration.isPressed
        let animates = !self.reduceMotion && !self.systemReduceMotion && self.isEnabled
        configuration.label
            .opacity(pressed ? Self.pressedOpacity : 1)
            .animation(
                pressed || !animates ? nil : .easeOut(duration: Self.releaseDuration),
                value: pressed
            )
            .scaleEffect(pressed && animates ? self.pressScale : 1)
            .animation(
                animates ? (pressed ? CardMotion.pressCurve : CardMotion.releaseSpring) : nil,
                value: pressed
            )
    }
}
