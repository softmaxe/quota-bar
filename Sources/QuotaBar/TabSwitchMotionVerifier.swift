#if DEBUG
import Foundation

/// Proves the tab pill stretches rather than slides, and that it stays a selection the whole way
/// across: the shape never inverts, never collapses, and is never sitting between the two
/// segments covering neither. Two durations on their own do not imply any of that, so this walks
/// the curve the animation walks and looks at the shape it makes.
enum TabSwitchMotionVerifier {
    /// Two segments the width the real labels come out at, with the bar's own 2pt gap.
    private static let source = (minX: 0.0, maxX: 80.0)
    private static let destination = (minX: 82.0, maxX: 156.0)
    /// A click has to be finished inside this. Past it the window stops feeling like it answered.
    private static let budget: TimeInterval = 0.2
    private static let samples = 240

    static func run() -> Never {
        Self.require(
            TabSwitchMotion.leadDuration < TabSwitchMotion.trailDuration,
            "the leading edge outruns the trailing one; equal durations are a plain slide"
        )
        Self.require(
            TabSwitchMotion.trailDuration < Self.budget,
            "the travel settles in \(TabSwitchMotion.trailDuration)s, past the \(Self.budget)s budget"
        )

        let rightward = TabSwitchMotion.edgeDurations(movingRight: true)
        Self.require(
            rightward.maxX == TabSwitchMotion.leadDuration
                && rightward.minX == TabSwitchMotion.trailDuration,
            "moving right, the right edge is the one that leaves first"
        )
        let leftward = TabSwitchMotion.edgeDurations(movingRight: false)
        Self.require(
            leftward.minX == TabSwitchMotion.leadDuration
                && leftward.maxX == TabSwitchMotion.trailDuration,
            "moving left, the left edge is the one that leaves first"
        )

        Self.require(
            TabSwitchMotion.progress(at: 0, duration: TabSwitchMotion.leadDuration) == 0,
            "the curve starts where the pill already is"
        )
        Self.require(
            abs(TabSwitchMotion.progress(
                at: TabSwitchMotion.leadDuration,
                duration: TabSwitchMotion.leadDuration
            ) - 1) < 1e-6,
            "the curve arrives, rather than approaching"
        )

        Self.walk(from: Self.source, to: Self.destination, movingRight: true)
        Self.walk(from: Self.destination, to: Self.source, movingRight: false)

        let curves = TabSwitchMotion.edgeCurves(movingRight: true, reduceMotion: true)
        Self.require(
            curves.minX == nil && curves.maxX == nil,
            "Reduce Motion turns the travel into a cut rather than a slower travel"
        )
        let moving = TabSwitchMotion.edgeCurves(movingRight: true, reduceMotion: false)
        Self.require(
            moving.minX != nil && moving.maxX != nil,
            "the pill travels when motion is not reduced"
        )

        print("tab switch motion verification passed")
        exit(0)
    }

    /// Samples the pill across one whole move and checks the shape it makes at every frame.
    private static func walk(
        from source: (minX: Double, maxX: Double),
        to destination: (minX: Double, maxX: Double),
        movingRight: Bool
    ) {
        let durations = TabSwitchMotion.edgeDurations(movingRight: movingRight)
        let sourceCenter = (source.minX + source.maxX) / 2
        let destinationCenter = (destination.minX + destination.maxX) / 2
        let span = max(source.maxX, destination.maxX) - min(source.minX, destination.minX)
        let widest = max(source.maxX - source.minX, destination.maxX - destination.minX)
        let direction = movingRight ? "rightward" : "leftward"

        var peakWidth = 0.0
        for step in 0...Self.samples {
            let time = TabSwitchMotion.trailDuration * Double(step) / Double(Self.samples)
            let minX = source.minX + (destination.minX - source.minX)
                * TabSwitchMotion.progress(at: time, duration: durations.minX)
            let maxX = source.maxX + (destination.maxX - source.maxX)
                * TabSwitchMotion.progress(at: time, duration: durations.maxX)
            let width = maxX - minX
            peakWidth = max(peakWidth, width)

            Self.require(
                width > 0,
                "\(direction) at \(Self.round(time))s the pill is \(Self.round(width))pt wide; "
                    + "an edge overtook the other one"
            )
            Self.require(
                width <= span + 1e-6,
                "\(direction) at \(Self.round(time))s the pill is \(Self.round(width))pt wide, "
                    + "wider than the \(Self.round(span))pt the two segments occupy"
            )
            // The selection is never nowhere: whatever the pill is doing, one of the two labels
            // is under it.
            Self.require(
                (minX <= sourceCenter && sourceCenter <= maxX)
                    || (minX <= destinationCenter && destinationCenter <= maxX),
                "\(direction) at \(Self.round(time))s the pill spans "
                    + "\(Self.round(minX))–\(Self.round(maxX))pt, covering neither label"
            )
        }

        // What separates this treatment from a slide: the shape genuinely grows on the way.
        Self.require(
            peakWidth > widest + 4,
            "\(direction) the pill peaks at \(Self.round(peakWidth))pt against a widest segment "
                + "of \(Self.round(widest))pt; it is sliding, not stretching"
        )
    }

    private static func round(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        VerifierReport.require(condition(), message, label: "tab-switch-motion verification")
    }
}
#endif
