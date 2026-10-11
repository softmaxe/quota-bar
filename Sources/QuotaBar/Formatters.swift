import QuotaBarCore
import Foundation

enum Formatters {
    /// "4h 47m", "6d 10h" — the coarse two-unit form CodexBar uses for reset countdowns.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "3:30 PM", "Sat 3:30 PM", "Sep 2, 3:30 PM" — the wall clock the reset countdown is
    /// counting down to. A bare time is only unambiguous for today, so the day is spelled out
    /// from tomorrow on, and the weekday gives way to a date once it would wrap around.
    static func resetClock(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = Self.style(calendar, locale).hour().minute().format(date)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        if days <= 0 { return time }
        if days < 7 {
            let weekday = Self.style(calendar, locale).weekday(.abbreviated).format(date)
            return "\(weekday) \(time)"
        }
        let day = Self.style(calendar, locale).month(.abbreviated).day().format(date)
        return "\(day), \(time)"
    }

    /// Field-free base style: the caller adds only the components it wants, and the calendar
    /// carries the time zone so a fixed one makes the output testable.
    private static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    /// "just now", "5m ago", "2h ago".
    static func relativeAge(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// Percentages render as whole numbers, matching the menu bar icon's quantization.
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "$0.00", "$507.13". Cents matter here because a day can be genuinely tiny.
    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Compact axis label: "$90", "$1.2K".
    static func compactCost(_ value: Double) -> String {
        if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        if value >= 10 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    /// "2026-08-24" — the key a `CostDay` is filed under.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        DayKey.make(from: date, calendar: calendar)
    }

    /// "2026-08-24" -> "Aug 24".
    static func dayLabel(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month) else { return dayKey }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month - 1]) \(day)"
    }

    /// "67M", "637M", "1.2B" — token counts are large enough that digits stop being readable.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return "\(count)"
    }
}
