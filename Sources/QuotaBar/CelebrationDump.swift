#if DEBUG
import QuotaBarCore
import AppKit
import SwiftUI

/// `--dump-card-celebration <dir> [provider]` writes the shared reset choreography as the menu
/// card draws it, for `Scripts/readme_assets.sh`.
@MainActor
enum CelebrationDump {
    /// Writes the choreography the way the card draws it: the shipped headline over the shipped
    /// bar, at the card's width and on the card's ground.
    static func dumpCardFrames(directory: String, provider: Provider, fps: Double = 25) {
        let root = OffscreenCapture.directory(directory)

        let step = 1 / max(1, fps)
        var time: TimeInterval = 0
        var index = 0
        // A beat of the settled card on each end, so a looping export does not cut straight from
        // the landing back to the empty bar.
        let tail = QuotaCelebration.duration + 0.6
        while time < tail {
            let frame = CelebrationCardFrame(
                elapsed: min(time, QuotaCelebration.duration),
                startPercent: 18,
                provider: provider
            )
            OffscreenCapture.renderPNG(
                frame,
                named: String(format: "frame-%04d", index),
                into: root
            )
            time += step
            index += 1
        }
        print("wrote \(index) card celebration frames to \(root.path)")
    }
}

/// One frozen frame of the reset as the menu card shows it. The headline and the glow are the
/// shipped views; the bar is redrawn here because the shipped one owns a clock of its own and a
/// still cannot hand it a time.
private struct CelebrationCardFrame: View {
    let elapsed: TimeInterval
    let startPercent: Double
    let provider: Provider

    private var tint: Color { Theme.accent(for: self.provider) }

    private var percent: Double {
        QuotaCelebration.fillPercent(at: self.elapsed, from: self.startPercent, to: 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuotaHeadline(
                    title: "Session",
                    percent: self.percent,
                    tint: self.tint,
                    frame: QuotaCelebrationFrame(
                        elapsed: self.elapsed,
                        percent: self.percent,
                        isReplay: false
                    )
                )
                Spacer(minLength: 8)
                Text("Resets in 5h 00m")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            self.bar
            Text("Lasts until reset")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 96, alignment: .center)
        .background(OffscreenCapture.groundColor)
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        Canvas { context, size in
            let corner = CGSize(width: size.height / 2, height: size.height / 2)
            let rect = CGRect(origin: .zero, size: size)
            context.clip(to: Path(rect))
            context.fill(Path(roundedRect: rect, cornerSize: corner), with: .color(Theme.progressTrack))

            let fillRect = CGRect(x: 0, y: 0, width: size.width * self.percent / 100, height: size.height)
            guard fillRect.width > 0 else { return }
            let fillPath = Path(roundedRect: fillRect, cornerSize: corner)
            context.fill(fillPath, with: .color(self.tint))

            let shine = QuotaCelebration.headShineOpacity(at: self.elapsed)
            if shine > 0.01 {
                let glow = CGRect(x: fillRect.maxX - 14, y: 0, width: 16, height: size.height)
                context.fill(
                    Path(roundedRect: glow, cornerSize: corner).intersection(fillPath),
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0), .white.opacity(0.9 * shine)]),
                        startPoint: CGPoint(x: glow.minX, y: 0),
                        endPoint: CGPoint(x: glow.maxX, y: 0)
                    )
                )
            }
            let flash = QuotaCelebration.flashOpacity(at: self.elapsed)
            if flash > 0.01 {
                context.fill(fillPath, with: .color(.white.opacity(flash)))
            }
        }
        .frame(height: 6)
        .scaleEffect(QuotaCelebration.barScale(at: self.elapsed), anchor: .center)
        .overlay {
            QuotaCelebrationLayer(
                elapsed: self.elapsed,
                tint: self.tint,
                startPercent: self.startPercent,
                targetPercent: 100,
                inset: 20
            )
            .frame(height: 96)
            .padding(.horizontal, -20)
        }
    }
}

#endif
