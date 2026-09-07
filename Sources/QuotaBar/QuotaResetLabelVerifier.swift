#if DEBUG
import QuotaBarCore
import AppKit
import Foundation
import SwiftUI

/// Proves the reset label's two faces read correctly, and that clicking one swaps to the other.
/// The whole point of the clock face is planning around a reset, so a label that names the wrong
/// day is worse than no label: every case that adds or drops the day is pinned here.
@MainActor
enum QuotaResetLabelVerifier {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")

    static func run() -> Never {
        // Friday, 28 August 2026, 14:04 local.
        let now = Self.date(2026, 8, 28, 14, 4)

        Self.expect(
            resetsAt: now.addingTimeInterval(86 * 60),
            mode: .countdown,
            now: now,
            "Resets in 1h 26m"
        )
        Self.expect(
            resetsAt: now.addingTimeInterval(5 * 86_400),
            mode: .countdown,
            now: now,
            "Resets in 5d 0h"
        )

        // Later today: the time alone cannot be read as any other day.
        Self.expect(
            resetsAt: Self.date(2026, 8, 28, 15, 30),
            mode: .clock,
            now: now,
            "Resets 3:30 PM"
        )
        // Half an hour away but across midnight — short countdown, different day.
        Self.expect(
            resetsAt: Self.date(2026, 8, 29, 0, 30),
            mode: .clock,
            now: Self.date(2026, 8, 28, 23, 59),
            "Resets Sat 12:30 AM"
        )
        Self.expect(
            resetsAt: Self.date(2026, 9, 3, 9, 0),
            mode: .clock,
            now: now,
            "Resets Thu 9:00 AM"
        )
        // A week out, where a weekday would name the day the reader is standing on.
        Self.expect(
            resetsAt: Self.date(2026, 9, 7, 9, 0),
            mode: .clock,
            now: now,
            "Resets Sep 7, 9:00 AM"
        )
        // Already past: the countdown floors at zero rather than counting up.
        Self.expect(
            resetsAt: now.addingTimeInterval(-600),
            mode: .countdown,
            now: now,
            "Resets in 0m"
        )

        Self.require(
            QuotaResetDisplayMode.countdown.toggled == .clock
                && QuotaResetDisplayMode.clock.toggled == .countdown,
            "clicking the label does not swap the two faces"
        )

        let layoutFailures = Self.layoutFailures()
        VerifierReport.finish(
            layoutFailures,
            label: "quota-reset-label verification",
            passed: "quota reset label text and 280pt card layout passed"
        )

    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? Self.calendar
        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        guard let date = calendar.date(from: components) else {
            VerifierReport.fail("could not build a fixture date", label: "quota-reset-label verification")
        }
        return date
    }

    /// Foundation separates the time from AM/PM with a narrow no-break space, which is right on
    /// screen and unreadable in a diff; the fixtures spell it as a plain space.
    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func expect(
        resetsAt: Date,
        mode: QuotaResetDisplayMode,
        now: Date,
        _ expected: String
    ) {
        let normalized = Self.normalized(
            QuotaResetLabel.text(
                resetsAt: resetsAt,
                mode: mode,
                now: now,
                calendar: Self.calendar,
                locale: Self.locale
            )
        )
        Self.require(
            normalized == expected,
            "expected \"\(expected)\", got \"\(normalized)\""
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        VerifierReport.require(condition(), message, label: "quota-reset-label verification")
    }

    private static func layoutFailures() -> [String] {
        // The arm64 runner already proved the 280pt card does not truncate; Intel can skip.
        guard GPURenderCheck.skipReason == nil else { return [] }
        let now = Self.date(2026, 8, 30, 9, 0, calendar: .current)
        let countdownReset = now.addingTimeInterval((7 * 86_400) + (3 * 3_600))
        let clockReset = Self.date(2026, 9, 6, 12, 45, calendar: .current)
        return Self.layoutFailures(mode: .countdown, now: now, reset: countdownReset)
            + Self.layoutFailures(mode: .clock, now: now, reset: clockReset)
    }

    private static func layoutFailures(
        mode: QuotaResetDisplayMode,
        now: Date,
        reset: Date
    ) -> [String] {
        var failures: [String] = []
        let resetText = QuotaResetLabel.text(resetsAt: reset, mode: mode, now: now)
        let normalizedResetText = Self.normalized(resetText)
        let expectedResetText = mode == .countdown
            ? "Resets in 7d 3h"
            : "Resets Sep 6, 12:45 PM"
        if normalizedResetText != expectedResetText {
            failures.append(
                "\(mode) layout fixture expected \"\(expectedResetText)\", got \"\(normalizedResetText)\""
            )
        }

        let snapshot = UsageSnapshot(
            provider: .codex,
            session: UsageWindow(
                usedPercent: 0,
                resetsAt: reset,
                windowSeconds: 18_000
            ),
            weekly: nil,
            planLabel: "Plus",
            credits: nil,
            fetchedAt: now
        )
        let hosting = NSHostingView(rootView: MenuCardView(
            provider: .codex,
            display: ProviderDisplay(snapshot: snapshot),
            isRefreshing: false,
            animatesFill: false,
            now: now,
            quotaResetDisplayMode: mode
        ))
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 280, height: hosting.fittingSize.height)
        )
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        let probes = Self.layoutProbes(in: hosting)
        guard let headlineProbe = probes.first(where: { $0.probeIdentifier == "headline" }) else {
            window.orderOut(nil)
            failures.append("the hosted card exposed no headline layout probe")
            return failures
        }
        guard let resetProbe = probes.first(where: { $0.probeIdentifier == "reset" }) else {
            window.orderOut(nil)
            failures.append("the hosted card exposed no reset layout probe")
            return failures
        }
        let headlineFrame = headlineProbe.convert(headlineProbe.bounds, to: hosting)
        let resetFrame = resetProbe.convert(resetProbe.bounds, to: hosting)

        let resetIdeal = NSHostingView(rootView: Text(resetText).font(.system(size: 11)).lineLimit(1))
        let headlineIdeal = NSHostingView(rootView: QuotaHeadline(
            title: "Session",
            percent: 100,
            tint: Theme.accent(for: .codex),
            frame: nil
        ))

        let resetIntrinsicWidth = resetIdeal.fittingSize.width
        if resetFrame.width + 0.5 < resetIntrinsicWidth {
            failures.append(
                "\(mode) reset label was compressed to \(Self.round(resetFrame.width))pt; "
                    + "its \(Self.round(resetIntrinsicWidth))pt intrinsic width was not preserved"
            )
        }
        let headlineIntrinsic = headlineIdeal.fittingSize
        if headlineFrame.width + 1 < headlineIntrinsic.width {
            failures.append(
                "\(mode) headline was compressed to \(Self.round(headlineFrame.width))pt; "
                    + "its \(Self.round(headlineIntrinsic.width))pt intrinsic width was not preserved"
            )
        }
        if headlineFrame.height > headlineIntrinsic.height + 1 {
            failures.append(
                "\(mode) headline wrapped to \(Self.round(headlineFrame.height))pt high; "
                    + "its single-line height is \(Self.round(headlineIntrinsic.height))pt"
            )
        }
        let contentMaxX = hosting.bounds.maxX - 14
        if resetFrame.maxX > contentMaxX + 0.5 {
            failures.append(
                "\(mode) reset label ended at \(Self.round(resetFrame.maxX))pt, outside the "
                    + "card content edge at \(Self.round(contentMaxX))pt"
            )
        }
        window.orderOut(nil)
        return failures
    }

    private static func layoutProbes(in view: NSView) -> [QuotaLayoutProbeView] {
        view.subviews.flatMap { subview in
            let own = subview as? QuotaLayoutProbeView
            return (own.map { [$0] } ?? []) + Self.layoutProbes(in: subview)
        }
    }

    private static func round(_ value: CGFloat) -> CGFloat {
        (value * 10).rounded() / 10
    }
}
#endif
