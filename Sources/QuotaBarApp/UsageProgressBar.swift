// Adapted from CodexBar (MIT, © 2026 Peter Steinberger): Sources/CodexBar/UsageProgressBar.swift
// Kept: the single-Canvas track, fill, and pace marker.
// Dropped: quota/workday markers, highlight-state theming, and accessibility values.
// Added: animated value changes and the reset animation that resumes from the final reading of the
// previous quota window.

import AppKit
import SwiftUI

/// Progress fill for one quota window. Presenting an existing reading is static, a window rollover
/// sweeps in, and ordinary spending glides from the value already on screen.
struct UsageProgressBar: View {
    /// Percentage *remaining*, 0...100 — the bar fills from the left with what is left.
    let percent: Double
    let tint: Color
    /// Where the fill would sit if the budget were being spent evenly, in remaining percent.
    let pacePercent: Double?
    /// Burning faster than the clock. The marker stays neutral; the outcome line carries the color.
    let paceIsDeficit: Bool
    /// The window is spent: the track takes a red tint so an empty bar never reads as a blank one.
    let isExhausted: Bool
    /// A saved reading: the pace tick steps back with the grey fill.
    let isStale: Bool
    /// Offscreen renders capture a single frame, so they need the bar to start at its final value.
    let animatesFill: Bool
    /// Non-zero, and changing, means this window reset: play the celebration instead of static
    /// presentation. Zero for every bar that has nothing to celebrate.
    let celebrationToken: Int
    /// The final remaining percentage observed before this window reset.
    let celebrationStartPercent: Double?
    /// Session and weekly bars opt in to a hidden five-click replay. Other uses stay inert.
    let allowsCelebrationReplay: Bool
    /// Where the bar publishes the frame it is drawing, so the headline above it can render the
    /// same choreography. The bar stays the only clock; nothing else decides when a reset plays.
    let celebrationRelay: QuotaCelebrationRelay?
    private let reduceMotion: () -> Bool

    @Environment(\.displayScale) private var displayScale

    /// Drives ordinary value changes between provider readings.
    @State private var displayedPercent: Double = 0
    /// Owns the celebration's frame clock; nil elapsed means nothing is playing.
    @StateObject private var celebration = CelebrationClock()
    /// Captures the reading that the hidden replay charges from and returns to.
    @State private var replayStartPercent: Double?

    private static let pacePunchWidth: CGFloat = 3.5
    private static let paceStripeWidth: CGFloat = 1.5
    private static let trackHeight: CGFloat = 6
    /// How far the pace marker reaches above and below the track, so it reads as a target.
    private static let markerOverhang: CGFloat = 2
    /// How far the celebration canvas reaches past each end of the bar.
    private static let celebrationInset: CGFloat = 20
    /// Tall enough that the glow fades out before it reaches the canvas edge; the card clips it
    /// long before that, which is the boundary that should be doing the cutting.
    private static let celebrationHeight: CGFloat = 170
    /// A window that rolls over jumps the remaining percentage up by far more than spending ever
    /// moves it down between two refreshes, which is what separates a reset from ordinary drift.
    private static let rolloverJumpPoints: Double = 5
    private static let rolloverDuration: TimeInterval = 0.95
    private static let glideDuration: TimeInterval = 0.25

    init(
        percent: Double,
        tint: Color,
        pacePercent: Double? = nil,
        paceIsDeficit: Bool = false,
        isExhausted: Bool = false,
        isStale: Bool = false,
        animatesFill: Bool = true,
        celebrationToken: Int = 0,
        celebrationStartPercent: Double? = nil,
        allowsCelebrationReplay: Bool = false,
        celebrationRelay: QuotaCelebrationRelay? = nil,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.percent = percent
        self.tint = tint
        self.pacePercent = pacePercent
        self.paceIsDeficit = paceIsDeficit
        self.isExhausted = isExhausted
        self.isStale = isStale
        self.animatesFill = animatesFill
        self.celebrationToken = celebrationToken
        self.celebrationStartPercent = celebrationStartPercent
        self.allowsCelebrationReplay = allowsCelebrationReplay
        self.celebrationRelay = celebrationRelay
        self.reduceMotion = reduceMotion
        self._displayedPercent = State(initialValue: min(100, max(0, percent)))
    }

    private var clamped: Double { min(100, max(0, self.percent)) }

    var body: some View {
        // Everything is drawn in one Canvas. CodexBar found that SwiftUI compositing modifiers
        // (.blendMode, .compositingGroup) trigger shader compilation on macOS 26 that can make the
        // status item icon disappear; a single Canvas uses Core Graphics directly and avoids it.
        Canvas { context, canvasSize in
            let scale = max(self.displayScale, 1)
            let inset = Self.markerOverhang
            let size = CGSize(width: canvasSize.width, height: canvasSize.height - inset * 2)
            let cornerSize = CGSize(width: size.height / 2, height: size.height / 2)
            let rect = CGRect(origin: CGPoint(x: 0, y: inset), size: size)

            let trackPath = Path { $0.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(Theme.progressTrack))
            if self.isExhausted {
                context.stroke(
                    Path { $0.addRoundedRect(in: rect.insetBy(dx: 0.5, dy: 0.5), cornerSize: cornerSize) },
                    with: .color(Color.red.opacity(0.75)),
                    lineWidth: 1
                )
            }

            var fillWidth = size.width * min(100, max(0, self.fillPercent)) / 100
            // A fill that ends within a few points of the pace tick ends at the tick, so the two
            // never leave a sliver between them. The headline keeps the exact reading.
            if let pacePercent = self.pacePercent, self.celebration.elapsed == nil, fillWidth > 0 {
                let tick = size.width * min(100, max(0, pacePercent)) / 100
                if abs(fillWidth - tick) < 6 { fillWidth = tick }
            }
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: inset, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))

                if let time = self.celebration.elapsed {
                    // A bright edge riding the head, and then the whole fill washing white as it
                    // lands. Both are drawn inside the pill, so they inherit its rounded ends.
                    let shine = QuotaCelebration.headShineOpacity(at: time)
                    if shine > 0.01 {
                        let head = fillRect.maxX
                        let glow = CGRect(x: head - 14, y: inset, width: 16, height: size.height)
                        context.fill(
                            Path(roundedRect: glow, cornerSize: cornerSize).intersection(fillPath),
                            with: .linearGradient(
                                Gradient(colors: [
                                    .white.opacity(0),
                                    .white.opacity(0.9 * shine),
                                ]),
                                startPoint: CGPoint(x: glow.minX, y: 0),
                                endPoint: CGPoint(x: glow.maxX, y: 0)
                            )
                        )
                    }
                    let flash = QuotaCelebration.flashOpacity(at: time)
                    if flash > 0.01 {
                        context.fill(fillPath, with: .color(.white.opacity(flash)))
                    }
                }
            }

            // Pace tick, drawn last so it reads on top of both the track and the fill. It stands
            // a little proud of the track, in the label color, so it reads as a target rather than
            // as a notch in the fill.
            if let pacePercent = self.pacePercent {
                let x = size.width * min(100, max(0, pacePercent)) / 100
                let punchRect = Self.markerRect(x: x, height: canvasSize.height, width: Self.pacePunchWidth, scale: scale)
                    .insetBy(dx: 0, dy: inset)
                let stripeRect = Self.markerRect(
                    x: x,
                    height: canvasSize.height,
                    width: max(1 / scale, Self.paceStripeWidth),
                    scale: scale
                )
                context.blendMode = .destinationOut
                context.fill(Path(punchRect), with: .color(.white))
                context.blendMode = .normal
                context.fill(
                    Path(roundedRect: stripeRect, cornerRadius: stripeRect.width / 2),
                    with: .color(Color(nsColor: self.isStale ? .secondaryLabelColor : .labelColor).opacity(0.85))
                )
            }
        }
        .frame(height: Self.trackHeight + Self.markerOverhang * 2)
        .padding(.vertical, -Self.markerOverhang)
        .scaleEffect(self.barScale, anchor: .center)
        .opacity(self.barOpacity)
        // Outside the bar and unscaled: the glow is in the card's space, not the pill's.
        .overlay {
            if let time = self.celebration.elapsed {
                QuotaCelebrationLayer(
                    elapsed: time,
                    tint: self.tint,
                    startPercent: self.activeCelebrationStartPercent,
                    targetPercent: self.activeCelebrationTargetPercent,
                    inset: Self.celebrationInset
                )
                    .frame(height: Self.celebrationHeight)
                    .padding(.horizontal, -Self.celebrationInset)
            }
        }
        // The explicit shape keeps the transparent track and pace-marker cutout clickable too.
        .contentShape(Rectangle())
        .onTapGesture(count: 5) { self.startCelebrationReplay() }
        .onAppear {
            guard self.animatesFill else { return }
            // A card that opens with a celebration already queued starts on it, not on the static
            // presentation path.
            if self.startCelebrationIfWanted() { return }
            // Opening a card is not a quota event: show the current reading immediately.
            self.snapDisplayedPercent()
        }
        .onDisappear {
            self.celebration.stop()
            self.replayStartPercent = nil
            // Published here rather than left to the change handler: a view on its way out gets no
            // further updates, and a stale frame would freeze the headline mid-count if the card's
            // hosting view is reused the next time the menu opens.
            self.celebrationRelay?.publish(nil)
        }
        .onChange(of: self.celebration.elapsed) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                self.replayStartPercent = nil
            }
            self.publishFrame(at: newValue)
        }
        .onChange(of: self.celebrationToken) { _, _ in
            _ = self.startCelebrationIfWanted()
        }
        .onChange(of: self.percent) { oldValue, newValue in
            guard self.animatesFill else {
                self.displayedPercent = self.clamped
                return
            }
            guard !self.celebration.isRunning else {
                // The celebration is already driving the fill; keep the handoff value current.
                self.displayedPercent = self.clamped
                return
            }
            if newValue - oldValue >= Self.rolloverJumpPoints {
                self.sweepFromEmpty()
            } else {
                self.glide()
            }
        }
    }

    /// What the Canvas fills to: the choreography while a celebration plays, the animated value
    /// the rest of the time.
    private var fillPercent: Double {
        guard let time = self.celebration.elapsed else { return self.displayedPercent }
        return self.celebrationFill(at: time)
    }

    private func celebrationFill(at time: TimeInterval) -> Double {
        if let replayStartPercent {
            return QuotaCelebrationReplay.fillPercent(
                at: time,
                from: replayStartPercent,
                to: self.clamped
            )
        }
        return QuotaCelebration.fillPercent(
            at: time,
            from: self.celebrationStartPercent ?? 0,
            to: self.clamped
        )
    }

    /// Hands the current frame to whatever is drawing alongside the bar. Nil ends the sequence for
    /// the headline at the same instant it ends for the fill.
    private func publishFrame(at time: TimeInterval?) {
        guard let relay = self.celebrationRelay else { return }
        guard let time else {
            relay.publish(nil)
            return
        }
        relay.publish(QuotaCelebrationFrame(
            elapsed: time,
            isReplay: self.replayStartPercent != nil
        ))
    }

    private var barScale: CGSize {
        guard let time = self.celebration.elapsed else { return CGSize(width: 1, height: 1) }
        return QuotaCelebration.barScale(at: time)
    }

    private var barOpacity: Double {
        guard let time = self.celebration.elapsed, self.replayStartPercent != nil else { return 1 }
        return QuotaCelebrationReplay.opacity(at: time)
    }

    private var activeCelebrationStartPercent: Double {
        self.replayStartPercent ?? self.celebrationStartPercent ?? 0
    }

    private var activeCelebrationTargetPercent: Double {
        self.replayStartPercent == nil ? self.clamped : 100
    }

    /// Returns whether a celebration was started, so the caller knows to skip static presentation.
    @discardableResult
    private func startCelebrationIfWanted() -> Bool {
        guard self.celebrationToken != 0,
              self.celebrationStartPercent != nil,
              self.animatesFill
        else { return false }
        // Reduce Motion turns the whole thing off: a bar springing and glowing in the menu bar is
        // exactly what that setting exists to stop.
        guard !self.reduceMotion() else {
            self.snapDisplayedPercent()
            return true
        }
        self.replayStartPercent = nil
        // The clock owns the visible fill from the persisted pre-reset value to the new reading.
        // The handoff when it stops lands on that real value without a snap.
        self.snapDisplayedPercent()
        self.celebration.start(duration: QuotaCelebration.duration)
        return true
    }

    /// Replays the real reset choreography without mutating quota data, then dissolves back to the
    /// reading that is still current. SwiftUI's counted gesture owns the consecutive-click timing.
    private func startCelebrationReplay() {
        guard self.allowsCelebrationReplay,
              self.animatesFill,
              !self.celebration.isRunning,
              !self.reduceMotion()
        else { return }

        self.replayStartPercent = self.clamped
        self.snapDisplayedPercent()
        self.celebration.start(duration: QuotaCelebrationReplay.duration)
    }

    /// Writes the fill straight to the renderer with no interpolation, so the next animation
    /// starts from this value instead of blending across it.
    private func snapDisplayedPercent(to value: Double? = nil) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.displayedPercent = value ?? self.clamped }
    }

    /// Snaps to empty, then sweeps left to right. Used for a window rollover.
    private func sweepFromEmpty() {
        self.moveFill(fromEmpty: true)
    }

    /// Moves from wherever the bar already sits, the way a value normally drifts.
    private func glide() {
        self.moveFill(fromEmpty: false)
    }

    private func moveFill(fromEmpty: Bool) {
        Self.moveFill(to: self.clamped, fromEmpty: fromEmpty, reduceMotion: self.reduceMotion()) { value, animation in
            guard !self.celebration.isRunning else { return }
            if let animation {
                withAnimation(animation) { self.displayedPercent = value }
            } else {
                self.snapDisplayedPercent(to: value)
            }
        }
    }

    /// Scheduling is injectable so the rollover's deferred write can be checked without a frame clock.
    static func moveFill(
        to value: Double,
        fromEmpty: Bool,
        reduceMotion: Bool,
        update: @escaping (Double, Animation?) -> Void,
        schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        guard !reduceMotion else {
            update(value, nil)
            return
        }
        if fromEmpty {
            update(0, nil)
            // The empty state must reach the renderer before SwiftUI queues the sweep.
            schedule { update(value, .easeOut(duration: Self.rolloverDuration)) }
        } else {
            update(value, .timingCurve(0.16, 1, 0.3, 1, duration: Self.glideDuration))
        }
    }

    private static func markerRect(x: CGFloat, height: CGFloat, width: CGFloat, scale: CGFloat) -> CGRect {
        let align: (CGFloat) -> CGFloat = { ($0 * scale).rounded() / scale }
        return CGRect(x: align(x - width / 2), y: 0, width: width, height: align(height))
    }
}
