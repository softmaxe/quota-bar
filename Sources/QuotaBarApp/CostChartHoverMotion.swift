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

    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Keeps the selection cue close to the pointer as it moves between bars. Nil means change
    /// the selection without animating it at all, which is what Reduce Motion is asking for.
    static var selection: Animation? {
        Self.systemReduceMotion ? nil : .spring(response: 0.14, dampingFraction: 1)
    }
}
