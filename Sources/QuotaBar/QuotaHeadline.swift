import AppKit
import SwiftUI

/// "Session 3% left" — the line above one quota window's bar. Presenting a reading is static; a
/// reset makes the number arrive with the fill instead of being already correct while the bar is
/// still charging. It counts on the fill's own easing, blurs while the digits are turning fastest
/// so it resolves into the new reading rather than stopping on it, and joins the landing beat the
/// bar already owns.
struct QuotaHeadline: View {
    /// "Session" or "Weekly".
    let title: String
    /// The live reading, and what the line shows whenever nothing is playing.
    let percent: Double
    let tint: Color
    /// The frame the bar is drawing, or nil when it is not celebrating.
    let frame: QuotaCelebrationFrame?

    /// Shared with the unlimited row, which stands in the same slot and has to match it.
    static let font = Font.system(size: 14, weight: .semibold)

    private var displayedPercent: Double {
        min(100, max(0, self.frame?.percent ?? self.percent))
    }

    /// Only the digits blur. The words around them are not moving, and smearing those would read
    /// as the whole card going out of focus.
    private var blur: CGFloat {
        guard let frame else { return 0 }
        return QuotaNumberMotion.blurRadius * QuotaNumberMotion.speed(at: frame.elapsed)
    }

    private var flash: Double {
        guard let frame else { return 0 }
        return QuotaNumberMotion.flash(at: frame.elapsed)
    }

    private var scale: Double {
        guard let frame else { return 1 }
        return QuotaNumberMotion.scale(at: frame.elapsed)
    }

    /// The hidden replay dissolves the bar on its way back to the live reading; the number goes
    /// with it, or the return reads as a second quota event.
    private var opacity: Double {
        guard let frame, frame.isReplay else { return 1 }
        return QuotaCelebrationReplay.opacity(at: frame.elapsed)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(self.title) ")
                .font(Self.font)
            self.number
                .blur(radius: self.blur)
                .background { QuotaHeadlineGlow(elapsed: self.frame?.elapsed, tint: self.tint) }
            Text(" left")
                .font(Self.font)
        }
        .scaleEffect(self.scale, anchor: .leading)
        .opacity(self.opacity)
        // Three Texts so the number can be treated on its own; to VoiceOver it stays one line, and
        // one that reads the settled value rather than whatever frame the count is on.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.title) \(Formatters.percent(self.percent)) left")
    }

    /// The percentage going warm on the landing beat and cooling back to the label color. The
    /// tinted copy is drawn over the plain one, so the wash is warmth rather than a color swap.
    private var number: some View {
        let text = Formatters.percent(self.displayedPercent)
        return Text(text)
            .font(Self.font)
            .monospacedDigit()
            .overlay {
                Text(text)
                    .font(Self.font)
                    .monospacedDigit()
                    .foregroundStyle(self.tint.opacity(self.flash))
            }
    }
}

/// The bloom behind the digits: the glow the bar gets on the landing, in the label's own space so
/// it does not inherit the pop's scale.
private struct QuotaHeadlineGlow: View {
    let elapsed: TimeInterval?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard let elapsed, let bloom = QuotaNumberMotion.glow(at: elapsed) else { return }
            let radiusX = max(size.width, 30) * 0.75 * bloom.scale
            let radiusY = max(size.height, 16) * 1.3 * bloom.scale
            guard radiusX > 0, radiusY > 0 else { return }
            // Canvas radial gradients are circular, so the layer is scaled to get an ellipse
            // instead of the falloff being faked with concentric fills.
            context.drawLayer { layer in
                layer.translateBy(x: size.width / 2, y: size.height / 2)
                layer.scaleBy(x: 1, y: radiusY / radiusX)
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: -radiusX,
                        y: -radiusX,
                        width: radiusX * 2,
                        height: radiusX * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [
                            self.tint.opacity(bloom.opacity),
                            self.tint.opacity(0),
                        ]),
                        center: .zero,
                        startRadius: 0,
                        endRadius: radiusX
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}
