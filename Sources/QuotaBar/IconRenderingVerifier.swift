#if DEBUG
import AppKit

/// Pixel checks for the status-item icons. These exercise the final bitmap rather than
/// duplicating the renderer's geometry in a policy test. Samples are bitmap coordinates: 36px
/// square, rows counted from the top.
enum IconRenderingVerifier {
    @MainActor
    static func run() -> Never {
        var failures: [String] = []

        Self.expectRobot(failures: &failures)
        Self.expectFading(failures: &failures)
        Self.expectNoCornerDot(failures: &failures)
        Self.expectRed(failures: &failures)
        Self.expectMatchingGeometry(failures: &failures)

        VerifierReport.finish(
            failures,
            label: "icon rendering verification",
            passed: "status-item icon rendering checks passed"
        )
    }

    /// The antenna and head are drawn and both chevron eyes are cut through the head.
    private static func expectRobot(failures: inout [String]) {
        let icon = IconRenderer.makeIcon(hasReading: true, stale: false)
        Self.expect(icon, x: 17, y: 7, { $0 >= 0.99 }, "robot antenna was missing", &failures)
        Self.expect(icon, x: 17, y: 16, { $0 >= 0.99 }, "robot head was not filled", &failures)
        Self.expect(icon, x: 12, y: 21, { $0 <= 0.1 }, "left eye was not cut out", &failures)
        Self.expect(icon, x: 24, y: 21, { $0 <= 0.1 }, "right eye was not cut out", &failures)
    }

    /// No reading fades the robot further than a stale one.
    private static func expectFading(failures: inout [String]) {
        let stale = IconRenderer.makeIcon(hasReading: true, stale: true)
        let empty = IconRenderer.makeIcon(hasReading: false, stale: false)
        Self.expect(stale, x: 17, y: 16, { abs($0 - 0.55) <= 0.02 },
                    "a stale reading did not dim the robot", &failures)
        Self.expect(empty, x: 17, y: 16, { abs($0 - 0.45) <= 0.02 },
                    "no reading did not fade the robot", &failures)
    }

    /// The old hidden-provider alert sat here; neither healthy nor running-low icons draw it.
    private static func expectNoCornerDot(failures: inout [String]) {
        let plain = IconRenderer.makeIcon(hasReading: true, stale: false)
        let low = IconRenderer.makeIcon(hasReading: true, stale: false, runningLow: true)
        Self.expect(plain, x: 32, y: 4, { $0 <= 0.01 },
                    "the healthy robot still had a corner dot", &failures)
        Self.expect(low, x: 32, y: 4, { $0 <= 0.01 },
                    "the running-low robot had a corner dot", &failures)
    }

    /// Red is baked into a non-template image; everything else stays a template for the menu bar.
    private static func expectRed(failures: inout [String]) {
        let plain = IconRenderer.makeIcon(hasReading: true, stale: false)
        let low = IconRenderer.makeIcon(hasReading: true, stale: false, runningLow: true)
        if !plain.isTemplate { failures.append("the plain robot was not a template image") }
        if low.isTemplate { failures.append("the running-low robot was a template the menu bar would recolor") }
        guard let head = low.representations.compactMap({ $0 as? NSBitmapImageRep }).first?
            .colorAt(x: 17, y: 16)?.usingColorSpace(.sRGB) else {
            failures.append("the running-low robot had no bitmap")
            return
        }
        if !(head.redComponent > 0.8 && head.greenComponent < 0.4 && head.blueComponent < 0.4) {
            failures.append("the running-low robot was not red (\(head))")
        }
    }

    /// Template tinting and baked-in red must not change the robot's visible dimensions.
    private static func expectMatchingGeometry(failures: inout [String]) {
        let plain = IconRenderer.makeIcon(hasReading: true, stale: false)
        let low = IconRenderer.makeIcon(hasReading: true, stale: false, runningLow: true)
        guard plain.size == low.size else {
            failures.append("healthy and running-low robots had different point sizes")
            return
        }
        guard let plainBitmap = Self.bitmap(plain), let lowBitmap = Self.bitmap(low) else {
            failures.append("healthy or running-low robot had no bitmap for geometry comparison")
            return
        }
        guard plainBitmap.pixelsWide == lowBitmap.pixelsWide,
              plainBitmap.pixelsHigh == lowBitmap.pixelsHigh else {
            failures.append("healthy and running-low robots had different bitmap dimensions")
            return
        }

        for y in 0..<plainBitmap.pixelsHigh {
            for x in 0..<plainBitmap.pixelsWide {
                let plainAlpha = plainBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let lowAlpha = lowBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if abs(plainAlpha - lowAlpha) > 0.002 {
                    failures.append(
                        "healthy and running-low robots had different geometry " +
                        "(alpha \(plainAlpha) versus \(lowAlpha) at \(x),\(y))"
                    )
                    return
                }
            }
        }
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first
    }

    /// A missing bitmap reads as transparent, which fails every check that expects ink.
    private static func expect(
        _ image: NSImage,
        x: Int,
        y: Int,
        _ holds: (CGFloat) -> Bool,
        _ message: String,
        _ failures: inout [String]
    ) {
        let bitmap = Self.bitmap(image)
        let alpha = bitmap?.colorAt(x: x, y: y)?.alphaComponent ?? 0
        if !holds(alpha) {
            failures.append("\(message) (alpha \(alpha) at \(x),\(y))")
        }
    }
}

#endif
