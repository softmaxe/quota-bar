// Adapted from CodexBar (MIT, © 2026 Peter Steinberger): Sources/CodexBar/IconRenderer.swift
// Kept: the 18pt @2x bitmap and the image cache.
// Replaced: the Codex "face" and Claude "crab" with a tick gauge in the app icon's style.
// Dropped: the capsule meters, the Gemini/Antigravity/Factory/Warp decorations,
// blink/wiggle/tilt animation, status overlays, and the morph cache.

import AppKit

enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let litTicks: Int?
        let stale: Bool
    }

    private final class Cache: @unchecked Sendable {
        private var images: [CacheKey: NSImage] = [:]
        private let lock = NSLock()

        func image(for key: CacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.images[key]
        }

        func store(_ image: NSImage, for key: CacheKey) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.images[key] = image
        }
    }

    private static let cache = Cache()

    // MARK: - Entry point

    /// - Parameters:
    ///   - remainingPercent: what the gauge shows; nil before the first reading, which fades it.
    ///   - stale: dims the icon when the last refresh failed.
    static func makeIcon(
        remainingPercent: Double?,
        stale: Bool
    ) -> NSImage {
        let litTicks = remainingPercent.map(Gauge.litTicks(remainingPercent:))
        let key = CacheKey(litTicks: litTicks, stale: stale)
        if let cached = self.cache.image(for: key) { return cached }

        let image = self.render(
            litTicks: litTicks,
            stale: stale
        )
        self.cache.store(image, for: key)
        return image
    }

    // MARK: - Gauge

    private enum Gauge {
        static let tickCount = 11
        /// Degrees clockwise from twelve o'clock; the 270 degree sweep leaves its gap at the bottom.
        static let firstTickDegrees: CGFloat = -135
        static let tickSpacingDegrees: CGFloat = 27
        /// Sits above the canvas center because the gap at the bottom carries no ink. Points are y up.
        static let center = CGPoint(x: 9, y: 7.75)
        static let innerRadius: CGFloat = 5.75
        static let outerRadius: CGFloat = 8
        static let tickWidth: CGFloat = 1.5
        static let unlitAlpha: CGFloat = 0.3

        /// Any quota left lights a tick, so an empty gauge always means an empty window.
        static func litTicks(remainingPercent: Double) -> Int {
            guard remainingPercent > 0 else { return 0 }
            let ticks = (min(remainingPercent, 100) / 100 * Double(Self.tickCount)).rounded()
            return max(1, Int(ticks))
        }

        static func tick(_ index: Int) -> NSBezierPath {
            let radians = (Self.firstTickDegrees + CGFloat(index) * Self.tickSpacingDegrees) * .pi / 180
            let dx = sin(radians)
            let dy = cos(radians)

            let path = NSBezierPath()
            path.lineWidth = Self.tickWidth
            path.lineCapStyle = .round
            path.move(to: CGPoint(
                x: Self.center.x + dx * Self.innerRadius,
                y: Self.center.y + dy * Self.innerRadius
            ))
            path.line(to: CGPoint(
                x: Self.center.x + dx * Self.outerRadius,
                y: Self.center.y + dy * Self.outerRadius
            ))
            return path
        }
    }

    private static func render(
        litTicks: Int?,
        stale: Bool
    ) -> NSImage {
        self.renderImage {
            for index in 0..<Gauge.tickCount {
                let alpha: CGFloat
                if let litTicks {
                    let level: CGFloat = stale ? 0.55 : 1
                    alpha = index < litTicks ? level : level * Gauge.unlitAlpha
                } else {
                    // No reading at all: an even, faded gauge, so the icon still shows the app is alive.
                    alpha = 0.45
                }
                NSColor.labelColor.withAlphaComponent(alpha).setStroke()
                Gauge.tick(index).stroke()
            }
        }
    }

    // MARK: - Bitmap

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: Self.outputSize)

        if let rep = NSBitmapImageRep.rgba(
            pixelsWide: Int(Self.outputSize.width * Self.outputScale),
            pixelsHigh: Int(Self.outputSize.height * Self.outputScale)
        ) {
            rep.size = Self.outputSize
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                Self.withScaledContext(draw)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            Self.withScaledContext(draw)
            image.unlockFocus()
        }

        // Template mode lets the system tint the icon for light and dark menu bars.
        image.isTemplate = true
        return image
    }

    private static func withScaledContext(_ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            draw()
            return
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none
        draw()
        ctx.restoreGState()
    }
}
