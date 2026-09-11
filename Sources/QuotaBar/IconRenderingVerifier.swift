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
        Self.expectBadge(failures: &failures)
        Self.expectRed(failures: &failures)

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

    /// The corner dot appears only when asked for, at full strength even on a stale robot.
    private static func expectBadge(failures: inout [String]) {
        let plain = IconRenderer.makeIcon(hasReading: true, stale: false)
        let badged = IconRenderer.makeIcon(hasReading: true, stale: true, otherProviderLow: true)
        Self.expect(plain, x: 32, y: 4, { $0 <= 0.01 },
                    "the badge showed without being raised", &failures)
        Self.expect(badged, x: 32, y: 4, { $0 >= 0.99 },
                    "a raised badge was not drawn at full strength", &failures)
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

    /// A missing bitmap reads as transparent, which fails every check that expects ink.
    private static func expect(
        _ image: NSImage,
        x: Int,
        y: Int,
        _ holds: (CGFloat) -> Bool,
        _ message: String,
        _ failures: inout [String]
    ) {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let alpha = bitmap?.colorAt(x: x, y: y)?.alphaComponent ?? 0
        if !holds(alpha) {
            failures.append("\(message) (alpha \(alpha) at \(x),\(y))")
        }
    }
}

#endif
