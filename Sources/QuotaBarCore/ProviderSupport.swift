import Foundation

/// Timestamp parsing shared by the log scanners and both credential stores. The two formatters
/// are built once: `ISO8601DateFormatter` is expensive to construct relative to a single
/// `date(from:)`, and a full rescan calls this once per log line.
package enum ISO8601 {
    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Fractional seconds first, because that is what the session logs write; the plain form is
    /// the fallback for the API payloads that omit them.
    package static func parse(_ raw: String) -> Date? {
        if let date = Self.parseCanonicalUTC(raw) { return date }
        Self.formatterLock.lock()
        defer { Self.formatterLock.unlock() }
        if let date = Self.withFraction.date(from: raw) { return date }
        return Self.plain.date(from: raw)
    }

    /// Fast path for the shape written by Codex and Claude logs. Less common ISO8601 variants
    /// keep the formatter fallback above so this optimization does not narrow accepted input.
    private static func parseCanonicalUTC(_ raw: String) -> Date? {
        let contiguousResult: Date?? = raw.utf8.withContiguousStorageIfAvailable { bytes in
            Self.parseCanonicalUTC(bytes)
        }
        if let result = contiguousResult { return result }
        return Self.parseCanonicalUTC(Array(raw.utf8))
    }

    private static func parseCanonicalUTC<Bytes>(_ bytes: Bytes) -> Date?
    where Bytes: RandomAccessCollection, Bytes.Index == Int, Bytes.Element == UInt8 {
        guard bytes.count == 20 || (22...30).contains(bytes.count),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"), bytes.last == UInt8(ascii: "Z") else { return nil }
        if bytes.count > 20, bytes[19] != UInt8(ascii: ".") { return nil }

        guard let year = Self.decimal(bytes, 0, 4),
              let month = Self.decimal(bytes, 5, 2),
              let day = Self.decimal(bytes, 8, 2),
              let hour = Self.decimal(bytes, 11, 2),
              let minute = Self.decimal(bytes, 14, 2),
              let second = Self.decimal(bytes, 17, 2),
              year > 0, (1...12).contains(month),
              (1...Self.daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return nil
        }

        var milliseconds = 0
        if bytes.count > 20 {
            let digits = bytes.count - 21
            guard digits > 0, digits <= 9 else { return nil }
            for index in 20..<(bytes.count - 1) {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                if index < 23 {
                    milliseconds = milliseconds * 10 + Int(byte - UInt8(ascii: "0"))
                }
            }
            for _ in min(digits, 3)..<3 { milliseconds *= 10 }
        }

        let days = Self.daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + Int64(hour * 3_600 + minute * 60 + second)
        return Date(timeIntervalSince1970: Double(seconds) + Double(milliseconds) / 1_000)
    }

    private static func decimal<Bytes>(_ bytes: Bytes, _ start: Int, _ count: Int) -> Int?
    where Bytes: RandomAccessCollection, Bytes.Index == Int, Bytes.Element == UInt8 {
        var value = 0
        for index in start..<(start + count) {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) || year.isMultiple(of: 400) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Howard Hinnant's civil-date conversion, shifted so 1970-01-01 is day zero.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear >= 0 ? adjustedYear / 400 : (adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }
}

/// `$CODEX_HOME`, or `~/.codex` when it is unset or blank. The credential store, the usage
/// fetcher and the log scanner all have to agree on this, so they all read it from here.
enum CodexHome {
    static func url(env: [String: String]) -> URL {
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

/// JSON coercion shared by the two log scanners, whose payloads spell integers as either a
/// number or a string depending on which client wrote the line.
enum JSONNumber {
    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}

/// `plus` -> `Plus`, `free_workspace` -> `Free Workspace`. Both providers label plans this way.
enum PlanLabel {
    public static func humanize(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
