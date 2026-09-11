#if DEBUG
import QuotaBarCore
import AppKit

/// Pixel checks for the status-item icons. These exercise the final bitmap rather than
/// duplicating the renderer's geometry in a policy test. Samples are bitmap coordinates: 36px
/// square, rows counted from the top.
enum IconRenderingVerifier {
    @MainActor
    static func run() -> Never {
        var failures: [String] = []

        for provider in Provider.allCases {
            Self.expectRobot(provider: provider, failures: &failures)
        }
        Self.expectMeters(failures: &failures)
        Self.expectBadge(failures: &failures)
        Self.expectWeeklyOnlyUsesUnlimitedSessionLane(failures: &failures)

        VerifierReport.finish(
            failures,
            label: "icon rendering verification",
            passed: "status-item icon rendering checks passed"
        )
    }

    /// The antenna is drawn and each provider's eyes are punched through a full head.
    private static func expectRobot(provider: Provider, failures: inout [String]) {
        let icon = self.icon(provider: provider, primary: 100, weekly: 100)
        let eye = provider == .claude ? (x: 11, y: 11) : (x: 11, y: 10)
        if let alpha = self.alpha(icon, x: eye.x, y: eye.y), alpha > 0.01 {
            failures.append("\(provider.rawValue) robot eye was not visible (alpha \(alpha))")
        }
        if let alpha = self.alpha(icon, x: 18, y: 1), alpha < 0.99 {
            failures.append("\(provider.rawValue) robot antenna was missing (alpha \(alpha))")
        }
        // The other provider's eye shape leaves this pixel on the head.
        let otherEye = provider == .claude ? (x: 13, y: 10) : (x: 11, y: 13)
        if let alpha = self.alpha(icon, x: otherEye.x, y: otherEye.y), alpha < 0.99 {
            failures.append("\(provider.rawValue) robot wore the other provider's eyes (alpha \(alpha))")
        }
    }

    /// The head fills with the session and the body with the week, both from the left.
    private static func expectMeters(failures: inout [String]) {
        let icon = self.icon(provider: .codex, primary: 100, weekly: 50)
        if let alpha = self.alpha(icon, x: 27, y: 15), alpha < 0.99 {
            failures.append("a full session left the head unfilled (alpha \(alpha))")
        }
        if let alpha = self.alpha(icon, x: 5, y: 26), alpha < 0.99 {
            failures.append("half a week left the body's left side unfilled (alpha \(alpha))")
        }
        if let alpha = self.alpha(icon, x: 30, y: 26), alpha > 0.6 {
            failures.append("half a week filled the body's right side (alpha \(alpha))")
        }
    }

    /// The corner dot appears only when asked for, and stays clear of the head it overlaps.
    private static func expectBadge(failures: inout [String]) {
        let plain = self.icon(provider: .codex, primary: 100, weekly: 100)
        let badged = self.icon(provider: .codex, primary: 100, weekly: 100, badge: true)
        if let alpha = self.alpha(plain, x: 32, y: 4), alpha > 0.01 {
            failures.append("the badge showed without being raised (alpha \(alpha))")
        }
        if let alpha = self.alpha(badged, x: 32, y: 4), alpha < 0.99 {
            failures.append("a raised badge was not drawn (alpha \(alpha))")
        }
        if let alpha = self.alpha(badged, x: 29, y: 6), alpha > 0.5 {
            failures.append("the badge ran into the head's corner (alpha \(alpha))")
        }
    }

    private static func expectWeeklyOnlyUsesUnlimitedSessionLane(failures: inout [String]) {
        let expected = self.icon(provider: .codex, primary: 100, weekly: 50)
        let weeklyOnly = self.icon(provider: .codex, primary: nil, weekly: 50)
        guard let expectedBitmap = self.bitmap(expected),
              let weeklyBitmap = self.bitmap(weeklyOnly),
              let expectedData = expectedBitmap.bitmapData,
              let weeklyData = weeklyBitmap.bitmapData else {
            failures.append("weekly-only Codex icon did not expose bitmap data")
            return
        }

        let expectedBytes = Data(bytes: expectedData, count: expectedBitmap.bytesPerRow * expectedBitmap.pixelsHigh)
        let weeklyBytes = Data(bytes: weeklyData, count: weeklyBitmap.bytesPerRow * weeklyBitmap.pixelsHigh)
        if expectedBytes != weeklyBytes {
            failures.append("weekly-only Codex quota did not keep a full head")
        }
    }

    private static func icon(
        provider: Provider,
        primary: Double?,
        weekly: Double?,
        badge: Bool = false
    ) -> NSImage {
        IconRenderer.makeIcon(
            provider: provider,
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            stale: false,
            otherProviderLow: badge
        )
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first
    }

    /// nil only when the bitmap is missing, which the byte comparison reports on its own.
    private static func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat? {
        self.bitmap(image)?.colorAt(x: x, y: y)?.alphaComponent
    }
}

#endif
