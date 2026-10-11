// Adapted from CodexBar (MIT, © 2026 Peter Steinberger): Sources/CodexBar/IconRenderer.swift
// Kept: the 18pt @2x bitmap and the image cache.
// Replaced: the Codex "face" and Claude "crab" with the Material Design Icons robot-excited mark,
// the glyph Omarchy's agents bar widget shows.
// Dropped: the capsule meters, the Gemini/Antigravity/Factory/Warp decorations,
// blink/wiggle/tilt animation, status overlays, and the morph cache.

import AppKit

enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let hasReading: Bool
        let stale: Bool
        let runningLow: Bool
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

    /// The robot carries no percentages, only whether the provider on show is running low.
    /// - Parameters:
    ///   - hasReading: false before the first snapshot arrives, which fades the robot.
    ///   - stale: dims the icon when the last refresh failed.
    ///   - runningLow: paints the icon red for the provider on show.
    static func makeIcon(
        hasReading: Bool,
        stale: Bool,
        runningLow: Bool = false
    ) -> NSImage {
        let key = CacheKey(hasReading: hasReading, stale: stale, runningLow: runningLow)
        if let cached = self.cache.image(for: key) { return cached }

        let image = self.render(
            hasReading: hasReading,
            stale: stale,
            runningLow: runningLow
        )
        self.cache.store(image, for: key)
        return image
    }

    // MARK: - Robot

    private enum Robot {
        /// MDI's 24-unit viewBox drawn at 16pt, inset 1pt, so the mark fills the 18pt canvas the
        /// way it fills a 16px icon font slot in Omarchy's bar. Points are y up.
        static let unit: CGFloat = 16.0 / 24.0

        static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: 1 + x * unit, y: 17 - y * unit)
        }

        /// `robot-excited` from Material Design Icons 7.4.47 (Apache-2.0), transcribed from its
        /// SVG path. The two chevron eyes are separate subpaths cut out by the even-odd rule.
        static let path: NSBezierPath = {
            let path = NSBezierPath()
            path.windingRule = .evenOdd

            func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: point(x, y)) }
            func line(_ x: CGFloat, _ y: CGFloat) { path.line(to: point(x, y)) }
            func curve(
                _ x1: CGFloat, _ y1: CGFloat,
                _ x2: CGFloat, _ y2: CGFloat,
                _ x: CGFloat, _ y: CGFloat
            ) {
                path.curve(to: point(x, y), controlPoint1: point(x1, y1), controlPoint2: point(x2, y2))
            }

            // Body, ears, head, and antenna.
            move(22, 14)
            line(21, 14)
            curve(21, 10.13, 17.87, 7, 14, 7)
            line(13, 7)
            line(13, 5.73)
            curve(13.6, 5.39, 14, 4.74, 14, 4)
            curve(14, 2.9, 13.11, 2, 12, 2)
            curve(10.89, 2, 10, 2.9, 10, 4) // SVG "S": first control reflects the previous one
            curve(10, 4.74, 10.4, 5.39, 11, 5.73)
            line(11, 7)
            line(10, 7)
            curve(6.13, 7, 3, 10.13, 3, 14)
            line(2, 14)
            curve(1.45, 14, 1, 14.45, 1, 15)
            line(1, 18)
            curve(1, 18.55, 1.45, 19, 2, 19)
            line(3, 19)
            line(3, 20)
            curve(3, 21.11, 3.9, 22, 5, 22)
            line(19, 22)
            curve(20.11, 22, 21, 21.11, 21, 20)
            line(21, 19)
            line(22, 19)
            curve(22.55, 19, 23, 18.55, 23, 18)
            line(23, 15)
            curve(23, 14.45, 22.55, 14, 22, 14)
            path.close()

            for dx: CGFloat in [0, 9] {
                move(8.68 + dx, 17.04)
                line(7.5 + dx, 15.86)
                line(6.32 + dx, 17.04)
                line(5.14 + dx, 15.86)
                line(7.5 + dx, 13.5)
                line(9.86 + dx, 15.86)
                path.close()
            }
            return path
        }()
    }

    private static func render(
        hasReading: Bool,
        stale: Bool,
        runningLow: Bool
    ) -> NSImage {
        // The menu bar ignores a status button's contentTintColor on template images, so red has
        // to be baked into a non-template image.
        self.renderImage(template: !runningLow) {
            let baseFill = runningLow ? NSColor.systemRed : NSColor.labelColor
            // No reading at all: a faded robot, so the icon still shows the app is alive.
            let alpha: CGFloat = !hasReading ? 0.45 : (stale ? 0.55 : 1)
            baseFill.withAlphaComponent(alpha).setFill()
            Robot.path.fill()
        }
    }

    // MARK: - Bitmap

    private static func renderImage(template: Bool, _ draw: () -> Void) -> NSImage {
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
        image.isTemplate = template
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
