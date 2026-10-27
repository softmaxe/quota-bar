import Foundation
import SwiftUI

/// Brief disclosure motion keeps the change of state visible without delaying the next action.
enum DisclosureMotion {
    static let openDuration: TimeInterval = 0.16

    static var openCurve: Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: Self.openDuration)
    }

    /// Nil rather than a curve under Reduce Motion, which turns every change back into a cut.
    static func open(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Self.openCurve
    }
}

/// The disclosure control itself: one glyph taking a quarter turn, rather than two glyphs
/// swapping places. Callers set the color, because the group header and the rows inside it are
/// deliberately not the same weight.
struct DisclosureChevron: View {
    let isOpen: Bool
    var size: CGFloat = 9
    var reduceMotion = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: self.size, weight: .semibold))
            .rotationEffect(.degrees(self.isOpen ? 90 : 0))
            .animation(DisclosureMotion.open(reduceMotion: self.reduceMotion), value: self.isOpen)
    }
}
