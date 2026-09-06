import AppKit
import CoreGraphics
import SwiftUI

/// How the cost chart changes which bar is highlighted. A hover is the pointer's own motion and
/// has to keep up with it; clearing hover is not a move the reader aimed at anything, so it
/// is allowed to take longer and to arrive with zero velocity — the shape `QuotaCelebrationReplay`
/// already uses to come back from the landing.
///
/// The selected bar is also marked by a rule under the baseline, so the highlight reads as a shape
/// and not only as a tone. The mark sits below the bars rather than on them because every bar's
/// height is a quantity the reader is comparing: a bar that grows under the pointer is a bar whose
/// height briefly means something other than what it means everywhere else on the chart. That is a
/// state rather than a motion: Reduce Motion changes how the mark arrives, never where it sits.
///
/// The label on that bar has a second change of its own — a click swaps its unit between tokens
/// and cost — and it lives here too, so everything the highlight can do is timed in one place.
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

    /// A move between bars, on the spring that carries the mark with the tone.
    static let hoverResponse: TimeInterval = 0.27
    /// Internal rather than private so the README film strip can sample the same spring.
    static let hoverDamping: Double = 0.9
    /// The return to rest is longer and critically damped, so the highlight disappears without
    /// springing away from the pointer.
    static let clearResponse: TimeInterval = 0.33
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

    /// The label belongs to the bar, so it arrives the way the bar does: rising into place as it
    /// fades in, rather than blinking on above a bar that is still moving.
    static let labelTransition: AnyTransition = .opacity.combined(with: .offset(y: 4))

    // MARK: - Breakdown

    /// A day's model list is the one thing on this card the reader opens rather than points at, so
    /// it is the one change allowed to take its time. The extra rows unroll out of the row above
    /// and fade in, and leave the same way, on a curve that eases out of rest and back into it --
    /// still the longest move on the card, but only just: past this the click stops feeling like
    /// it landed.
    static let breakdownDuration: TimeInterval = 0.34

    /// The shape the reveal takes, sampled by hand. Both halves of it are stepped rather than
    /// handed to an animator: the card's height is an AppKit frame -- an open menu re-lays itself
    /// out whenever its item view resizes -- and the rows inside it follow the same reading, which
    /// is the only way the two stay together. Smoothstep rather than SwiftUI's cubic bezier: over
    /// a third of a second the two agree to well within a frame.
    static func breakdownEase(_ progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        return progress * progress * (3 - 2 * progress)
    }

    /// One step of the sweep. The distance is what gets rounded, not the height: the card grows by
    /// exactly the strip the rows open, and the strip rounds the same product -- so the card's edge
    /// and the rows inside it move by the same whole points rather than by two roundings of one
    /// curve. Whole points because the card is laid out from the top edge of a view whose height is
    /// what moves, and a fraction there puts every line on a fraction of a pixel, where text
    /// shimmers instead of sliding.
    static func breakdownHeight(start: CGFloat, target: CGFloat, progress: Double) -> CGFloat {
        start + ((target - start) * Self.breakdownEase(progress)).rounded()
    }

    // MARK: - Unit swap

    /// Clicking the selected bar swaps its label between tokens and cost. The click lands on a
    /// target the reader is already pointing at, so the swap has no distance to cover and can be
    /// quick; it still has to read as one number becoming another rather than as two numbers
    /// trading places.
    static let swapDuration: TimeInterval = 0.26

    /// The swap is the reset headline's treatment, sized for a 10 pt label: the old unit blurs
    /// out and the new one resolves out of the blur. Nothing moves, which is what says the two
    /// readings are the same quantity counted differently — a positional swap would say the
    /// label had been replaced by a different label.
    ///
    /// Read off `QuotaNumberMotion.blurRadius`, but held here rather than taken from it: the
    /// headline applies that radius through a decaying multiplier on 14 pt text, and this is the
    /// full radius on a 10 pt one. Two amplitudes that happen to agree, not one shared amplitude.
    static let swapBlur: CGFloat = 2.6
    /// How small the number is while it is still blurred. Enough to feel unresolved, not enough
    /// to read as a separate zoom.
    static let swapScale: Double = 0.86

    static func swapAnimation(reduceMotion: Bool, timeScale: Double = 1) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: Self.scaled(Self.swapDuration, timeScale: timeScale))
    }

    static let swapTransition: AnyTransition = .modifier(
        active: LabelResolve(progress: 1),
        identity: LabelResolve(progress: 0)
    )

    /// The demo windows slow these curves down so a quarter-second response can be judged by
    /// eye. A playback rate, so a slower rate is a longer animation.
    static func scaled(_ duration: TimeInterval, timeScale: Double) -> TimeInterval {
        duration / max(0.01, timeScale)
    }
}

/// One end of the unit swap: at full strength the number is blurred and slightly small, at
/// identity it is the label as it is read.
struct LabelResolve: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: CostChartHoverMotion.swapBlur * self.progress)
            .scaleEffect(1 - (1 - CostChartHoverMotion.swapScale) * self.progress)
            .opacity(1 - self.progress)
    }
}
