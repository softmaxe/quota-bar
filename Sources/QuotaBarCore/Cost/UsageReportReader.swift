import Foundation

public struct UsageReportTotals: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cacheWrite1h: Int = 0,
        cost: Double = 0,
        unpricedTokens: Int = 0,
        total: Int? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cost = cost
        self.unpricedTokens = unpricedTokens
        self.total = total ?? input + output + cacheRead + cacheWrite
    }
}

public struct UsageReportDay: Codable, Sendable, Equatable {
    public let day: String
    public let recorded: Bool
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(day: String, recorded: Bool, totals: UsageReportTotals = UsageReportTotals()) {
        self.day = day
        self.recorded = recorded
        self.input = totals.input
        self.output = totals.output
        self.cacheRead = totals.cacheRead
        self.cacheWrite = totals.cacheWrite
        self.cacheWrite1h = totals.cacheWrite1h
        self.cost = totals.cost
        self.unpricedTokens = totals.unpricedTokens
        self.total = totals.total
    }
}

public struct UsageReportNamedUsage: Codable, Sendable, Equatable {
    public let name: String
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let cacheWrite1h: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let total: Int

    public init(name: String, totals: UsageReportTotals = UsageReportTotals()) {
        self.name = name
        self.input = totals.input
        self.output = totals.output
        self.cacheRead = totals.cacheRead
        self.cacheWrite = totals.cacheWrite
        self.cacheWrite1h = totals.cacheWrite1h
        self.cost = totals.cost
        self.unpricedTokens = totals.unpricedTokens
        self.total = totals.total
    }
}

public struct UsageReportWeekday: Codable, Sendable, Equatable {
    public let name: String
    public let total: Int

    public init(name: String, total: Int) {
        self.name = name
        self.total = total
    }
}

public struct UsageReportSnapshot: Codable, Sendable, Equatable {
    public let period: String
    public let capturedAt: String
    public let timezone: String
    public let totals: UsageReportTotals
    public let days: [UsageReportDay]
    public let models: [UsageReportNamedUsage]
    public let sources: [UsageReportNamedUsage]
    public let weekdays: [UsageReportWeekday]

    public init(
        period: String,
        capturedAt: String,
        timezone: String,
        totals: UsageReportTotals,
        days: [UsageReportDay],
        models: [UsageReportNamedUsage],
        sources: [UsageReportNamedUsage],
        weekdays: [UsageReportWeekday]
    ) {
        self.period = period
        self.capturedAt = capturedAt
        self.timezone = timezone
        self.totals = totals
        self.days = days
        self.models = models
        self.sources = sources
        self.weekdays = weekdays
    }

    public var hasRecordedUsage: Bool {
        self.days.contains(where: \.recorded)
    }

    public var defaultFilename: String {
        let endDay = self.days.last?.day ?? "usage"
        return "QuotaBar-Usage-\(endDay).html"
    }
}

public enum UsageReportReaderError: LocalizedError, Equatable {
    case invalidWindowDays(Int)
    case databaseMissing(String)
    case openFailed(String)
    case corruptSchema(String)
    case queryFailed(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidWindowDays(days):
            "Usage report window must contain between 1 and 30 days; received \(days)."
        case let .databaseMissing(path):
            "The usage database does not exist at \(path)."
        case let .openFailed(message):
            "Could not open the usage database for reading: \(message)"
        case let .corruptSchema(message):
            "The usage database schema is incomplete or corrupt: \(message)"
        case let .queryFailed(message):
            "Could not read usage report data: \(message)"
        case let .invalidData(message):
            "The usage database contains invalid report data: \(message)"
        }
    }
}

/// Reads recorded usage from the local scan cache without scanning logs or changing schema, and
/// prices it the same way the popover does: each day at the rate card's rates for that day.
public enum UsageReportReader {
    fileprivate static let maximumSafeInteger = RecordedUsageReader.reportMaximumSafeInteger

    public static func read(
        databaseURL: URL = CostService.defaultDatabaseURL,
        windowDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        rateCard: RateCard = RateCard()
    ) throws -> UsageReportSnapshot {
        try self.read(databaseURL: databaseURL, windowDays: windowDays, now: now, calendar: calendar,
                      rateCard: rateCard, afterSchemaDiscovery: nil)
    }

    /// Observes the real read transaction for deterministic writer synchronization in tests.
    package static func read(
        databaseURL: URL,
        windowDays: Int,
        now: Date,
        calendar: Calendar,
        rateCard: RateCard,
        afterSchemaDiscovery: (() throws -> Void)?
    ) throws -> UsageReportSnapshot {
        guard (1 ... 30).contains(windowDays) else {
            throw UsageReportReaderError.invalidWindowDays(windowDays)
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw UsageReportReaderError.databaseMissing(databaseURL.path)
        }

        let range = try self.dayRange(windowDays: windowDays, now: now, calendar: calendar)
        let rows: [RecordedUsageReader.DayUsage]
        do {
            let reader = try RecordedUsageReader(databaseURL: databaseURL)
            rows = try reader.reportUsage(
                fromDay: range.keys[0],
                throughDay: range.keys[windowDays - 1],
                afterSchemaDiscovery: afterSchemaDiscovery
            )
        } catch let error as RecordedUsageReaderError {
            switch error {
            case let .openFailed(message): throw UsageReportReaderError.openFailed(message)
            case let .corruptSchema(message): throw UsageReportReaderError.corruptSchema(message)
            case let .queryFailed(message): throw UsageReportReaderError.queryFailed(message)
            case let .invalidData(message): throw UsageReportReaderError.invalidData(message)
            }
        }

        var total = CheckedUsage()
        var dayTotals: [String: CheckedUsage] = [:]
        var modelTotals: [String: CheckedUsage] = [:]
        var sourceTotals: [CostUsageSource: CheckedUsage] = [:]
        var recordedDays: Set<String> = []
        let validDays = Set(range.keys)

        for row in rows {
            guard validDays.contains(row.day) else {
                throw UsageReportReaderError.invalidData("unexpected day \(row.day)")
            }
            var usage = CheckedUsage(
                input: Int64(row.tokens.input),
                output: Int64(row.tokens.output),
                cacheRead: Int64(row.tokens.cacheRead),
                cacheWrite: Int64(row.tokens.cacheWrite),
                cacheWrite1h: Int64(row.tokens.cacheWrite1h)
            )
            if let cost = rateCard.cost(
                of: row.tokens,
                model: row.tier.model,
                provider: row.tier.source.provider,
                day: row.day,
                fast: row.tier.isFast,
                longContext: row.tier.longContext
            ) {
                usage.cost = cost
            } else {
                usage.unpricedTokens = Int64(try usage.snapshot(label: "unpriced usage").total)
            }
            _ = try usage.snapshot(label: "\(row.tier.source.displayName) \(row.day) \(row.tier.model)")
            try total.add(usage)
            try dayTotals[row.day, default: CheckedUsage()].add(usage)
            try modelTotals[row.tier.model, default: CheckedUsage()].add(usage)
            try sourceTotals[row.tier.source, default: CheckedUsage()].add(usage)
            recordedDays.insert(row.day)
        }

        let totals = try total.snapshot(label: "report total")
        let days = try range.keys.map { key in
            UsageReportDay(
                day: key,
                recorded: recordedDays.contains(key),
                totals: try dayTotals[key, default: CheckedUsage()].snapshot(label: "day \(key)")
            )
        }
        let models = try modelTotals.map { name, usage in
            UsageReportNamedUsage(name: name, totals: try usage.snapshot(label: "model \(name)"))
        }.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name < $1.name
        }
        let sources = try sourceTotals.sorted {
            $0.key.displayOrder < $1.key.displayOrder
        }.map { source, usage in
            UsageReportNamedUsage(name: source.displayName,
                                  totals: try usage.snapshot(label: "source \(source.displayName)"))
        }

        var weekdayTotals = Array(repeating: CheckedUsage(), count: 7)
        for index in range.keys.indices where recordedDays.contains(range.keys[index]) {
            let weekday = calendar.component(.weekday, from: range.dates[index])
            guard (1 ... 7).contains(weekday) else {
                throw UsageReportReaderError.invalidData("calendar returned invalid weekday \(weekday)")
            }
            try weekdayTotals[weekday - 1].add(dayTotals[range.keys[index], default: CheckedUsage()])
        }
        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let mondayFirst = [2, 3, 4, 5, 6, 7, 1]
        let weekdays = try mondayFirst.map { weekday in
            let usage = try weekdayTotals[weekday - 1].snapshot(label: weekdayNames[weekday - 1])
            return UsageReportWeekday(name: weekdayNames[weekday - 1], total: usage.total)
        }

        return UsageReportSnapshot(
            period: "\(range.keys[0]) 至 \(range.keys[windowDays - 1])",
            capturedAt: self.timestamp(now),
            timezone: calendar.timeZone.identifier,
            totals: totals,
            days: days,
            models: models,
            sources: sources,
            weekdays: weekdays
        )
    }

    private static func dayRange(
        windowDays: Int,
        now: Date,
        calendar: Calendar
    ) throws -> (dates: [Date], keys: [String]) {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw UsageReportReaderError.invalidData("capture date is not finite")
        }
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - windowDays, to: end) else {
            throw UsageReportReaderError.invalidData("could not calculate report date range")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var dates: [Date] = []
        var keys: [String] = []
        for offset in 0 ..< windowDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw UsageReportReaderError.invalidData("could not calculate report day \(offset + 1)")
            }
            dates.append(date)
            keys.append(formatter.string(from: date))
        }
        guard Set(keys).count == windowDays else {
            throw UsageReportReaderError.invalidData("calendar produced duplicate report days")
        }
        return (dates, keys)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct CheckedUsage {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var cost: Double = 0
    var unpricedTokens: Int64 = 0

    mutating func add(_ other: Self) throws {
        self.input = try self.checkedAdd(self.input, other.input, field: "input")
        self.output = try self.checkedAdd(self.output, other.output, field: "output")
        self.cacheRead = try self.checkedAdd(self.cacheRead, other.cacheRead, field: "cacheRead")
        self.cacheWrite = try self.checkedAdd(self.cacheWrite, other.cacheWrite, field: "cacheWrite")
        self.cacheWrite1h = try self.checkedAdd(self.cacheWrite1h, other.cacheWrite1h, field: "cacheWrite1h")
        self.unpricedTokens = try self.checkedAdd(
            self.unpricedTokens,
            other.unpricedTokens,
            field: "unpricedTokens"
        )
        self.cost += other.cost
        guard self.cost.isFinite, self.cost >= 0 else {
            throw UsageReportReaderError.invalidData("cost is negative or not finite")
        }
    }

    func snapshot(label: String) throws -> UsageReportTotals {
        for (field, value) in [
            ("input", self.input),
            ("output", self.output),
            ("cacheRead", self.cacheRead),
            ("cacheWrite", self.cacheWrite),
            ("cacheWrite1h", self.cacheWrite1h),
            ("unpricedTokens", self.unpricedTokens),
        ] where value < 0 || value > UsageReportReader.maximumSafeInteger {
            throw UsageReportReaderError.invalidData("\(label) \(field) is outside the safe integer range")
        }
        guard self.cacheWrite1h <= self.cacheWrite else {
            throw UsageReportReaderError.invalidData("\(label) cacheWrite1h exceeds cacheWrite")
        }
        let subtotal = try self.checkedAdd(self.input, self.output, field: "total")
        let cached = try self.checkedAdd(self.cacheRead, self.cacheWrite, field: "total")
        let total = try self.checkedAdd(subtotal, cached, field: "total")
        guard self.unpricedTokens <= total else {
            throw UsageReportReaderError.invalidData("\(label) unpricedTokens exceeds total")
        }
        guard self.cost.isFinite, self.cost >= 0 else {
            throw UsageReportReaderError.invalidData("\(label) cost is negative or not finite")
        }
        return UsageReportTotals(
            input: Int(self.input),
            output: Int(self.output),
            cacheRead: Int(self.cacheRead),
            cacheWrite: Int(self.cacheWrite),
            cacheWrite1h: Int(self.cacheWrite1h),
            cost: self.cost,
            unpricedTokens: Int(self.unpricedTokens),
            total: Int(total)
        )
    }

    fileprivate func checkedAdd(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0, sum <= UsageReportReader.maximumSafeInteger else {
            throw UsageReportReaderError.invalidData("\(field) total is outside the safe integer range")
        }
        return sum
    }
}
