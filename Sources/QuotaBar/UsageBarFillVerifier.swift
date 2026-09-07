#if DEBUG
import AppKit
import SwiftUI

/// No XCTest without Xcode, so the fill policy is asserted from a launch flag the way the chart
/// highlighting and the menu toggles are.
enum UsageBarFillVerifier {
    private static let label = "usage bar fill verification"
    private static let passed = "usage bar rollover and drift fill checks passed"

    @MainActor
    static func run() -> Never {
        var failures: [String] = []

        // A window rollover: the provider hands back a full quota in one step.
        let rollover = UsageBarFillPolicy.onValueChange(from: 2, to: 100)
        guard case let .sweepFromEmpty(duration) = rollover else {
            failures.append("a 2% -> 100% rollover did not sweep, got \(rollover)")
            return VerifierReport.finish(failures, label: Self.label, passed: Self.passed)
        }
        if duration <= UsageBarFillPolicy.glideDuration {
            failures.append("the rollover sweep was not slower than ordinary value drift")
        }

        // Spending only ever moves the remaining percentage down, which must not restart the bar.
        if case .sweepFromEmpty = UsageBarFillPolicy.onValueChange(from: 93, to: 89) {
            failures.append("ordinary spending restarted the bar from empty")
        }

        // A refresh that lands one point higher is noise, not a rollover.
        if case .sweepFromEmpty = UsageBarFillPolicy.onValueChange(from: 89, to: 90) {
            failures.append("a one-point rise was mistaken for a window rollover")
        }

        // The threshold itself belongs to the rollover side.
        let atThreshold = UsageBarFillPolicy.onValueChange(
            from: 50,
            to: 50 + UsageBarFillPolicy.rolloverJumpPoints
        )
        if case .glide = atThreshold {
            failures.append("a rise of exactly the rollover threshold glided instead of sweeping")
        }

        // Headless runners without a GPU still exercise every fill-policy assertion above, while
        // a GPU-backed runner owns the pixel check below.
        if let reason = GPURenderCheck.skipReason {
            print("Skipping usage bar pixel check: \(reason).")
        } else {
            let marker = UsageProgressBar(
                percent: 50,
                tint: .cyan,
                pacePercent: 50,
                animatesFill: false
            )
            .frame(width: 100, height: 6)
            let renderer = ImageRenderer(content: marker)
            renderer.scale = 2
            if let image = renderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let leftAlpha = bitmap.colorAt(x: 96, y: 6)?.alphaComponent ?? 1
                let rightAlpha = bitmap.colorAt(x: 103, y: 6)?.alphaComponent ?? 1
                if leftAlpha > 0.01 || rightAlpha > 0.01 {
                    failures.append(
                        "the pace marker did not fully cut through both sides of the bar "
                            + "(left alpha \(leftAlpha), right alpha \(rightAlpha))"
                    )
                }
            } else {
                failures.append("the pace marker render check did not produce an image")
            }
        }

        return VerifierReport.finish(failures, label: Self.label, passed: Self.passed)
    }
}

#endif
