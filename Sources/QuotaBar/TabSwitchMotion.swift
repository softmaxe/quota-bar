import Foundation
import SwiftUI

/// How the settings window's tab selection travels. The pill is one shape whose two edges run the
/// same curve over different lengths: the edge facing the destination leaves first and the one
/// behind it catches up, so the selection briefly spans both segments rather than being in two
/// places or in none. The curve is the one the pricing table opens on — the app has a single
/// vocabulary for "this moved", not one per control.
enum TabSwitchMotion {
    /// The edge facing the destination.
    static let leadDuration: TimeInterval = 0.13
    /// The edge behind it. The gap between the two is the whole effect: too small and the pill
    /// reads as a plain slide, too large and it reads as tearing.
    static let trailDuration: TimeInterval = 0.18

    static var lead: Animation {
        .timingCurve(Self.control1.x, Self.control1.y, Self.control2.x, Self.control2.y,
                     duration: Self.leadDuration)
    }

    static var trail: Animation {
        .timingCurve(Self.control1.x, Self.control1.y, Self.control2.x, Self.control2.y,
                     duration: Self.trailDuration)
    }

    /// The pricing table's opening easing, as its two control points. Named rather than inlined
    /// because the verifier has to walk the same curve the animation does.
    static let control1 = (x: 0.16, y: 1.0)
    static let control2 = (x: 0.3, y: 1.0)

    /// Seconds each edge of the pill takes. The edge facing the destination is the fast one,
    /// whichever direction that happens to be.
    static func edgeDurations(movingRight: Bool) -> (minX: TimeInterval, maxX: TimeInterval) {
        movingRight
            ? (minX: Self.trailDuration, maxX: Self.leadDuration)
            : (minX: Self.leadDuration, maxX: Self.trailDuration)
    }

    /// The curves those durations stand for, or nil under Reduce Motion — which turns the travel
    /// back into a cut rather than into a slower travel.
    static func edgeCurves(
        movingRight: Bool,
        reduceMotion: Bool
    ) -> (minX: Animation?, maxX: Animation?) {
        guard !reduceMotion else { return (nil, nil) }
        let durations = Self.edgeDurations(movingRight: movingRight)
        return (
            minX: durations.minX == Self.leadDuration ? Self.lead : Self.trail,
            maxX: durations.maxX == Self.leadDuration ? Self.lead : Self.trail
        )
    }

#if DEBUG
    /// Where the curve has got to `time` seconds in. The animation solves this itself; this
    /// exists so the verifier can sample the pill's shape over the whole travel rather than
    /// trusting that two durations imply it.
    static func progress(at time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let fraction = min(max(time / duration, 0), 1)
        return Self.bezierY(atX: fraction)
    }

    /// A unit cubic Bézier from (0,0) to (1,1) through the two control points, solved for x by
    /// bisection. Twenty steps put the answer well inside a pixel at any width this bar has.
    private static func bezierY(atX x: Double) -> Double {
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<20 {
            let current = Self.bezier(t, Self.control1.x, Self.control2.x)
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return Self.bezier(t, Self.control1.y, Self.control2.y)
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
    }
#endif
}
