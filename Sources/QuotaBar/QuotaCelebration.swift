import CoreGraphics
import Foundation

/// One quota window. It also keeps five-hour and weekly reset tracking independent.
enum QuotaWindowKind: String, Hashable, CaseIterable {
    case session
    case weekly
}

/// Choreography for a quota reset: the fill resumes from the last pre-reset reading and
/// continuously slows into 100%. Nothing trails the head on the way there — the landing is the
/// whole event, synchronizing the bar pop, the flash, and a soft glow rising under the bar. The
/// landing has no edges anywhere: what says the quota is full is the whole bar going warm, not a
/// shape drawn on the point where the head stopped.
enum QuotaCelebration {
    // MARK: - Timeline

    /// One continuous exponential decay drives the fill all the way to its destination.
    static let landing: TimeInterval = 0.55
    static let sweepDuration = Self.landing
    /// How long the bar keeps springing after the head lands.
    static let popDuration: TimeInterval = 0.25
    /// The fill washes bright at the moment of landing and cools back to the tint.
    static let flashDuration: TimeInterval = 0.20
    /// The wide glow, and therefore the last thing left on screen.
    static let bloomDuration: TimeInterval = 0.25

    /// A beat of slack on the end, so the last frame the clock runs is genuinely empty whatever
    /// floating point does to the sum below.
    private static let coolDown: TimeInterval = 0.02

    /// When the landing has cooled off completely, and therefore when the clock stops.
    static var duration: TimeInterval {
        Self.landing
            + max(Self.popDuration, max(Self.flashDuration, Self.bloomDuration))
            + Self.coolDown
    }

    // MARK: - Fill

    /// The bar reaches most of the new fill early, then settles at the landing.
    static let fillDecay: Double = 5.2

    /// Share of the final percentage the bar shows, 0...1.
    static func fillFraction(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        guard time < Self.sweepDuration else { return 1 }
        let normalized = time / Self.sweepDuration
        return (1 - exp(-Self.fillDecay * normalized)) / (1 - exp(-Self.fillDecay))
    }

    static func fillPercent(at time: TimeInterval, from start: Double, to target: Double) -> Double {
        let from = min(100, max(0, start))
        let to = min(100, max(0, target))
        return from + (to - from) * Self.fillFraction(at: time)
    }

    /// A bright edge riding the head of the fill. Fades out as the head arrives so the landing
    /// reads as the flash, not as the shine stopping.
    static func headShineOpacity(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        let fadeIn = min(1, time / 0.04)
        let remaining = Self.landing - time
        guard remaining > 0 else { return 0 }
        return 0.5 * fadeIn * min(1, remaining / 0.10)
    }

    /// The whole fill washing white at the moment of landing.
    static func flashOpacity(at time: TimeInterval) -> Double {
        let age = time - Self.landing
        guard age >= 0, age < Self.flashDuration else { return 0 }
        return 0.26 * pow(1 - age / Self.flashDuration, 1.6)
    }

    // MARK: - Pop

    /// Scale for the bar itself. Height carries the pop — a 6 pt pill widening reads as a glitch,
    /// while the same pill growing taller reads as a bounce.
    static func barScale(at time: TimeInterval) -> CGSize {
        let age = time - Self.landing
        guard age >= 0, age < Self.popDuration else { return CGSize(width: 1, height: 1) }
        // One short pulse returns to rest exactly when the settling interval ends.
        let pulse = sin(.pi * age / Self.popDuration) * pow(1 - age / Self.popDuration, 1.3)
        return CGSize(width: 1 + 0.02 * pulse, height: 1 + 0.5 * pulse)
    }

    // MARK: - Origin

    /// Where along the bar the landing event is centred, as a fraction of the bar width. Short of
    /// the very end on purpose: the bar stops 14 pt from the card's right edge, and anything
    /// centred on the last pixel would have half of itself cut away by that edge.
    static let originX: Double = 0.92

    // MARK: - Head

    /// The bright mote riding the head of the fill, drawn outside the pill.
    struct Head: Equatable {
        let coreRadius: CGFloat
        let coreOpacity: Double
        let glowRadius: CGFloat
        let glowOpacity: Double
    }

    /// The head fades out into the landing rather than switching off on it. Nothing in this
    /// choreography has a hard edge, and that includes the way things stop.
    private static let headFadeOut: TimeInterval = 0.10

    static func head(at time: TimeInterval) -> Head? {
        guard time >= 0, time < Self.landing else { return nil }
        let pulse = 0.9 + 0.1 * sin(time * 14)
        let level = pulse * min(1, (Self.landing - time) / Self.headFadeOut)
        return Head(
            coreRadius: 2.4,
            coreOpacity: 0.7 * level,
            glowRadius: 9,
            glowOpacity: 0.14 * level
        )
    }

    // MARK: - Glow

    /// A soft ellipse with no edge of its own. Bar-local: `centre.x` measured from the bar's left
    /// edge, `centre.y` from its middle, positive downwards.
    struct Glow: Equatable {
        let centre: CGPoint
        let radiusX: CGFloat
        let radiusY: CGFloat
        let opacity: Double
    }

    private struct Bloom {
        let duration: TimeInterval
        /// Centre on the whole bar, or on the landing point.
        let spansBar: Bool
        /// Added to half the bar width when `spansBar`, the whole radius otherwise.
        let radiusX: CGFloat
        let radiusY: CGFloat
        let peak: Double
        /// Both glows swell rather than appearing at full size, which is what keeps a shape this
        /// large from reading as a flash of its own.
        let startScale: Double
    }

    /// The wide one says the whole bar is warm again; the tight one keeps the landing point
    /// legible without drawing anything there that has an outline.
    private static let blooms: [Bloom] = [
        Bloom(
            duration: Self.bloomDuration,
            spansBar: true,
            radiusX: 26,
            radiusY: 24,
            peak: 0.3,
            startScale: 0.72
        ),
        Bloom(
            duration: 0.20,
            spansBar: false,
            radiusX: 34,
            radiusY: 16,
            peak: 0.34,
            startScale: 0.5
        ),
    ]

    static func glows(at time: TimeInterval, barWidth: CGFloat) -> [Glow] {
        Self.blooms.compactMap { bloom in
            let age = time - Self.landing
            guard age >= 0, age < bloom.duration else { return nil }
            let progress = age / bloom.duration
            let eased = 1 - pow(1 - progress, 2.2)
            let scale = bloom.startScale + (1 - bloom.startScale) * eased
            let centreX = bloom.spansBar ? barWidth / 2 : barWidth * Self.originX
            let radiusX = bloom.spansBar ? barWidth / 2 + bloom.radiusX : bloom.radiusX
            return Glow(
                centre: CGPoint(x: centreX, y: 0),
                radiusX: radiusX * scale,
                radiusY: bloom.radiusY * scale,
                opacity: bloom.peak * pow(1 - progress, 1.7)
            )
        }
    }

}

/// The hidden replay keeps the approved reset choreography intact, then quietly returns the bar
/// to live data. One deterministic timeline avoids delayed callbacks inside an NSMenu run loop.
enum QuotaCelebrationReplay {
    static let returnDuration: TimeInterval = 0.82
    static var duration: TimeInterval { QuotaCelebration.duration + Self.returnDuration }

    private static let minimumOpacity = 0.52

    static func fillPercent(at time: TimeInterval, from start: Double, to target: Double) -> Double {
        let start = min(100, max(0, start))
        let target = min(100, max(0, target))
        guard time > QuotaCelebration.duration else {
            return QuotaCelebration.fillPercent(at: time, from: start, to: 100)
        }
        let progress = Self.returnProgress(at: time)
        return 100 + (target - 100) * Self.smoothStep(progress)
    }

    /// A restrained dissolve makes the change of direction read as an intentional return rather
    /// than a second quota event. The track never vanishes, preserving spatial continuity.
    static func opacity(at time: TimeInterval) -> Double {
        let progress = Self.returnProgress(at: time)
        guard progress > 0, progress < 1 else { return 1 }
        let distanceFromMiddle = abs(progress * 2 - 1)
        return Self.minimumOpacity
            + (1 - Self.minimumOpacity) * Self.smoothStep(distanceFromMiddle)
    }

    private static func returnProgress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - QuotaCelebration.duration) / Self.returnDuration))
    }

    /// Symmetric ease-in/ease-out with zero velocity at both ends.
    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}
