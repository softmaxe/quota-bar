import AppKit
import SwiftUI

/// Drives a celebration frame by frame. A `Timer` in `.common` mode rather than `TimelineView`:
/// the card lives inside an `NSMenu`, and menu tracking runs the run loop in its own mode where
/// anything scheduled on the default mode never fires.
@MainActor
final class CelebrationClock: ObservableObject {
    /// Seconds into the sequence, or nil when nothing is playing.
    @Published private(set) var elapsed: TimeInterval?

    private var timer: Timer?
    private var startedAt = Date()
    private var duration: TimeInterval = 0

    /// 120 Hz so the sweep is smooth on a ProMotion display; the work per frame is one small
    /// Canvas redraw.
    private static let frameInterval: TimeInterval = 1.0 / 120

    var isRunning: Bool { self.elapsed != nil }

    func start(duration: TimeInterval) {
        self.stop()
        self.duration = duration
        self.startedAt = Date()
        self.elapsed = 0

        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.elapsed = nil
    }

    private func tick() {
        let time = Date().timeIntervalSince(self.startedAt)
        if time >= self.duration {
            self.stop()
        } else {
            self.elapsed = time
        }
    }
}

/// Everything the reset animation draws outside the bar: the head riding the fill while it
/// charges, then the two glows that rise under it on the landing. One Canvas, no compositing
/// modifiers.
struct QuotaCelebrationLayer: View {
    let elapsed: TimeInterval
    let tint: Color
    let startPercent: Double
    let targetPercent: Double
    /// How far the canvas reaches past each end of the bar, so the glow has room to open.
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let barWidth = max(0, size.width - self.inset * 2)
            let centre = CGPoint(x: self.inset, y: size.height / 2)

            self.drawHead(in: &context, centre: centre, barWidth: barWidth)
            self.drawGlows(in: &context, centre: centre, barWidth: barWidth)
        }
        .allowsHitTesting(false)
    }

    private func drawHead(in context: inout GraphicsContext, centre: CGPoint, barWidth: CGFloat) {
        guard let head = QuotaCelebration.head(at: self.elapsed) else { return }
        let headPercent = QuotaCelebration.fillPercent(
            at: self.elapsed,
            from: self.startPercent,
            to: self.targetPercent
        )
        let headX = centre.x + barWidth * min(100, max(0, headPercent)) / 100
        let point = CGPoint(x: headX, y: centre.y)
        context.fill(
            Path(ellipseIn: Self.box(around: point, radius: head.glowRadius)),
            with: .color(self.tint.opacity(head.glowOpacity))
        )
        context.fill(
            Path(ellipseIn: Self.box(around: point, radius: head.coreRadius)),
            with: .color(.white.opacity(head.coreOpacity))
        )
    }

    /// Canvas radial gradients are circular, so the layer is scaled to get an ellipse instead of
    /// the falloff being faked with concentric fills.
    private func drawGlows(in context: inout GraphicsContext, centre: CGPoint, barWidth: CGFloat) {
        for glow in QuotaCelebration.glows(at: self.elapsed, barWidth: barWidth) {
            guard glow.radiusX > 0, glow.radiusY > 0 else { continue }
            let point = CGPoint(x: centre.x + glow.centre.x, y: centre.y + glow.centre.y)
            context.drawLayer { layer in
                layer.translateBy(x: point.x, y: point.y)
                layer.scaleBy(x: 1, y: glow.radiusY / glow.radiusX)
                layer.fill(
                    Path(ellipseIn: Self.box(around: .zero, radius: glow.radiusX)),
                    with: .radialGradient(
                        Gradient(colors: [
                            self.tint.opacity(glow.opacity),
                            self.tint.opacity(0),
                        ]),
                        center: .zero,
                        startRadius: 0,
                        endRadius: glow.radiusX
                    )
                )
            }
        }
    }

    private static func box(around point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }
}
