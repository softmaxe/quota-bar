import AppKit
import CoreGraphics
import SwiftUI

/// Chart marker geometry and the optional transitions for selection, units, and model disclosure.
/// The marker sits below the bars so no animation changes their quantitative heights.
enum CostChartHoverMotion {
    /// The mark under the selected bar: as thick as the bar's own corner radius, and far enough
    /// below the baseline to read as a separate thing rather than as part of the bar.
    static let markerHeight: CGFloat = 2
    static let markerGap: CGFloat = 3
    /// The strip the mark needs under the chart. The chart reserves it whether or not a bar is
    /// selected, so the card is the same height with the pointer on it as without.
    static var markerBand: CGFloat { Self.markerGap + Self.markerHeight }

    /// How wide the mark is on a bar that is not selected, as a share of the bar's width. It opens
    /// out of the bar's centre and closes back into it, so a move between neighbours reads as one
    /// mark travelling rather than as two fading past each other.
    static let markerRestWidth: Double = 0.3

    /// The mark's width on a bar that is `share` of the way selected, 0 to 1. The film strip walks
    /// this between two bars; the card only ever asks for the ends.
    static func markerWidth(share: Double) -> Double {
        let share = min(1, max(0, share))
        return Self.markerRestWidth + (1 - Self.markerRestWidth) * share
    }

    /// Keep the selection cue close to the pointer as it moves between bars.
    static let hoverResponse: TimeInterval = 0.14
    /// Internal rather than private so the README film strip can sample the same spring.
    static let hoverDamping: Double = 1
    /// Clearing the hover settles without pulling attention from the chart.
    static let clearResponse: TimeInterval = 0.16
    static let clearDamping: Double = 1

    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Nil means change the selection without animating it at all, which is what Reduce Motion is
    /// asking for.
    static func animation(
        clearingHover: Bool,
        reduceMotion: Bool,
        timeScale: Double = 1
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        let response = clearingHover ? Self.clearResponse : Self.hoverResponse
        let damping = clearingHover ? Self.clearDamping : Self.hoverDamping
        return .spring(
            response: Self.scaled(response, timeScale: timeScale),
            dampingFraction: damping
        )
    }

    /// The demo windows slow these curves down so a quarter-second response can be judged by
    /// eye. A playback rate, so a slower rate is a longer animation.
    static func scaled(_ duration: TimeInterval, timeScale: Double) -> TimeInterval {
        duration / max(0.01, timeScale)
    }
}
