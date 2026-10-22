@testable import QuotaBarApp
import QuotaBarCore
import Foundation

/// Checks reset-date boundaries and countdown clamping.
enum QuotaResetLabelTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")

    static func run() {
        // Friday, 28 August 2026, 14:04 local.
        let now = Self.date(2026, 8, 28, 14, 4)

        Self.expect(resetsAt: now.addingTimeInterval(86 * 60), mode: .countdown, now: now, "in 1h 26m")
        Self.expect(resetsAt: now.addingTimeInterval(5 * 86_400), mode: .countdown, now: now, "in 5d 0h")

        // Later today: the time alone cannot be read as any other day.
        Self.expect(resetsAt: Self.date(2026, 8, 28, 15, 30), mode: .clock, now: now, "3:30 PM")
        // Half an hour away but across midnight — short countdown, different day.
        Self.expect(
            resetsAt: Self.date(2026, 8, 29, 0, 30),
            mode: .clock,
            now: Self.date(2026, 8, 28, 23, 59),
            "Sat 12:30 AM"
        )
        Self.expect(resetsAt: Self.date(2026, 9, 3, 9, 0), mode: .clock, now: now, "Thu 9:00 AM")
        // A week out, where a weekday would name the day the reader is standing on.
        Self.expect(resetsAt: Self.date(2026, 9, 7, 9, 0), mode: .clock, now: now, "Sep 7, 9:00 AM")
        // Already past: the countdown floors at zero rather than counting up.
        Self.expect(resetsAt: now.addingTimeInterval(-600), mode: .countdown, now: now, "in 0m")
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let components = DateComponents(
            timeZone: Self.calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return Self.calendar.date(from: components)!
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
        _ expected: String,
        line: UInt = #line
    ) {
        let text = QuotaResetLabel.text(
            resetsAt: resetsAt,
            mode: mode,
            now: now,
            calendar: Self.calendar,
            locale: Self.locale
        )
        Harness.expectEqual(Self.normalized(text), expected, "reset label", line: line)
    }
}
