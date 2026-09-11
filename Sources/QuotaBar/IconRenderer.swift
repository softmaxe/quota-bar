// Adapted from CodexBar (MIT, © 2026 Peter Steinberger): Sources/CodexBar/IconRenderer.swift
// Kept: the 18pt @2x pixel grid and the capsule track/fill/stroke bar.
// Replaced: the Codex "face" and Claude "crab" with one robot shared by both providers.
// Dropped: the Gemini/Antigravity/Factory/Warp decorations, blink/wiggle/tilt animation,
// status overlays, and the morph cache.

import QuotaBarCore
import AppKit

enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2

    /// Everything is laid out in device pixels on a 2× grid, then converted to points, so
    /// edges land on pixel boundaries and the icon stays crisp at menu bar size.
    private struct PixelGrid {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat { CGFloat(px) / self.scale }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }
    }

    private static let grid = PixelGrid(scale: outputScale)

    private struct RectPx {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        func rect() -> CGRect { IconRenderer.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h) }
    }

    static func fillWidthPixels(remaining: Double, rectWidth: Int) -> Int {
        let clamped = max(0, min(remaining / 100, 1))
        return max(0, min(rectWidth, Int((CGFloat(rectWidth) * CGFloat(clamped)).rounded())))
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let provider: Provider
        let primary: Int
        let weekly: Int
        let stale: Bool
        let badge: Bool
    }

    private final class Cache: @unchecked Sendable {
        private var images: [CacheKey: NSImage] = [:]
        private var order: [CacheKey] = []
        private let lock = NSLock()

        func image(for key: CacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let image = self.images[key] else { return nil }
            if let index = self.order.firstIndex(of: key) {
                self.order.remove(at: index)
                self.order.append(key)
            }
            return image
        }

        func store(_ image: NSImage, for key: CacheKey, limit: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.images[key] = image
            self.order.removeAll { $0 == key }
            self.order.append(key)
            while self.order.count > limit {
                self.images.removeValue(forKey: self.order.removeFirst())
            }
        }
    }

    private static let cache = Cache()
    private static let cacheLimit = 64

    // MARK: - Entry point

    /// - Parameters:
    ///   - primaryRemaining: percentage left in the session window, 0...100.
    ///   - weeklyRemaining: percentage left in the weekly window, 0...100.
    ///   - stale: dims the icon when the last refresh failed.
    ///   - otherProviderLow: raises the corner badge for the provider the icon is not drawing.
    static func makeIcon(
        provider: Provider,
        primaryRemaining: Double?,
        weeklyRemaining: Double?,
        stale: Bool,
        otherProviderLow: Bool = false
    ) -> NSImage {
        // Quantize to whole percent so small fluctuations reuse a cached image.
        let key = CacheKey(
            provider: provider,
            primary: primaryRemaining.map { Int($0.rounded()) } ?? -1,
            weekly: weeklyRemaining.map { Int($0.rounded()) } ?? -1,
            stale: stale,
            badge: otherProviderLow
        )
        if let cached = self.cache.image(for: key) { return cached }

        let image = self.render(
            provider: provider,
            primaryRemaining: primaryRemaining,
            weeklyRemaining: weeklyRemaining,
            stale: stale,
            otherProviderLow: otherProviderLow
        )
        self.cache.store(image, for: key, limit: Self.cacheLimit)
        return image
    }

    // MARK: - Robot

    /// The robot's parts in device pixels, y up. The head is the session meter and the body the
    /// weekly one; the antenna, ears and neck carry no data and exist so the outline reads as a
    /// robot at 18pt. Every part is mirrored about the canvas centre except the badge.
    private enum Robot {
        static let head = RectPx(x: 5, y: 18, w: 26, h: 13)
        static let headCornerPx = 3
        static let body = RectPx(x: 1, y: 5, w: 34, h: 10)
        static let bodyCornerPx = 2

        static let frame: [RectPx] = [
            RectPx(x: 16, y: 33, w: 4, h: 2), // antenna tip
            RectPx(x: 17, y: 31, w: 2, h: 2), // antenna stem
            RectPx(x: 2, y: 22, w: 3, h: 5), // left ear
            RectPx(x: 31, y: 22, w: 3, h: 5), // right ear
            RectPx(x: 16, y: 15, w: 4, h: 3), // neck
        ]

        /// The one thing that still tells the providers apart: Claude keeps the crab's tall eye
        /// slits, Codex the face's square eyes.
        static func eyes(for provider: Provider) -> [RectPx] {
            switch provider {
            case .claude: [RectPx(x: 11, y: 22, w: 2, h: 5), RectPx(x: 23, y: 22, w: 2, h: 5)]
            case .codex: [RectPx(x: 10, y: 23, w: 4, h: 4), RectPx(x: 22, y: 23, w: 4, h: 4)]
            }
        }

        /// Top-right, clear of the ear, with a ring cut around it so it stays a separate dot where
        /// it overlaps the head's corner.
        static let badgeCenterPx = (x: 32, y: 32)
        static let badgeRadiusPx: CGFloat = 3
        static let badgeGapPx: CGFloat = 1.5
    }

    private static func render(
        provider: Provider,
        primaryRemaining: Double?,
        weeklyRemaining: Double?,
        stale: Bool,
        otherProviderLow: Bool
    ) -> NSImage {
        self.renderImage {
            let baseFill = NSColor.labelColor
            let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
            let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
            let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1.0)

            func drawLane(rectPx: RectPx, cornerRadiusPx: Int, remaining: Double?, alpha: CGFloat) {
                let rect = rectPx.rect()
                let radius = Self.grid.pt(cornerRadiusPx)

                let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
                trackPath.fill()

                // Stroke an inset path so the 1pt outline stays inside the pixel bounds.
                let strokeWidthPx = 2
                let insetPx = strokeWidthPx / 2
                let strokeRect = Self.grid.rect(
                    x: rectPx.x + insetPx,
                    y: rectPx.y + insetPx,
                    w: max(0, rectPx.w - insetPx * 2),
                    h: max(0, rectPx.h - insetPx * 2)
                )
                let strokePath = NSBezierPath(
                    roundedRect: strokeRect,
                    xRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)),
                    yRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx))
                )
                strokePath.lineWidth = CGFloat(strokeWidthPx) / Self.outputScale
                baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
                strokePath.stroke()

                // Clip to the lane and paint a plain rect so the progress edge stays straight.
                guard let remaining else { return }
                let fillWidthPx = Self.fillWidthPixels(remaining: remaining, rectWidth: rectPx.w)
                guard fillWidthPx > 0 else { return }
                NSGraphicsContext.current?.cgContext.saveGState()
                trackPath.addClip()
                fillColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(rect: Self.grid.rect(
                    x: rectPx.x,
                    y: rectPx.y,
                    w: fillWidthPx,
                    h: rectPx.h
                )).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }

            // No reading at all: an empty, faded robot, so the icon still shows the app is alive.
            let hasReading = primaryRemaining != nil || weeklyRemaining != nil
            let alpha: CGFloat = hasReading ? 1 : 0.45
            // With a weekly reading, a missing session is a plan without one, so the head stays
            // full to say it is unrestricted.
            let headRemaining = weeklyRemaining == nil ? primaryRemaining : (primaryRemaining ?? 100)

            drawLane(
                rectPx: Robot.head,
                cornerRadiusPx: Robot.headCornerPx,
                remaining: headRemaining,
                alpha: alpha
            )
            // A session reading on its own leaves the body faded rather than as an empty meter,
            // which would read as a weekly window run dry.
            drawLane(
                rectPx: Robot.body,
                cornerRadiusPx: Robot.bodyCornerPx,
                remaining: weeklyRemaining,
                alpha: weeklyRemaining == nil ? 0.45 : alpha
            )

            fillColor.withAlphaComponent(alpha).setFill()
            for part in Robot.frame {
                NSBezierPath(rect: part.rect()).fill()
            }

            let ctx = NSGraphicsContext.current?.cgContext
            // Punch the eyes out of the head rather than painting over it, so they read on
            // both a filled and an empty track.
            ctx?.saveGState()
            ctx?.setShouldAntialias(false)
            for eye in Robot.eyes(for: provider) {
                ctx?.clear(eye.rect())
            }
            ctx?.restoreGState()

            if otherProviderLow {
                let center = CGPoint(
                    x: Self.grid.pt(Robot.badgeCenterPx.x),
                    y: Self.grid.pt(Robot.badgeCenterPx.y)
                )
                func circle(radiusPx: CGFloat) -> NSBezierPath {
                    let radius = radiusPx / Self.outputScale
                    return NSBezierPath(ovalIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                }
                ctx?.saveGState()
                ctx?.setBlendMode(.clear)
                circle(radiusPx: Robot.badgeRadiusPx + Robot.badgeGapPx).fill()
                ctx?.restoreGState()
                // Full strength even when stale: it is about the other provider's reading.
                baseFill.withAlphaComponent(1).setFill()
                circle(radiusPx: Robot.badgeRadiusPx).fill()
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
