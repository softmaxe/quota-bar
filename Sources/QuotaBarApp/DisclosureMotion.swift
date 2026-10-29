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
