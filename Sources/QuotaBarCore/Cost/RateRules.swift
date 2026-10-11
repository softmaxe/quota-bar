// The rules every set of rates must follow, wherever it comes from. The price book and the user's
// override file both read rates through here, so a rate the book would refuse cannot reach billing
// through an override instead.

import Foundation

/// One way a set of rates breaks the rules, pinned to the key that breaks it.
public struct RateViolation: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Rule: Equatable, Sendable {
        /// Not one of the keys a rate set has.
        case unknownKey
        /// Not a finite number.
        case notANumber
        case negative
        /// `input` or `output`, which every rate set needs, is absent.
        case missing
        /// `thresholdTokens` is not a positive whole number within range.
        case thresholdNotPositiveWhole
        /// Long-context rates without the threshold that says when they apply. Reported against
        /// `thresholdTokens`.
        case longContextWithoutThreshold
    }

    public let key: String
    public let rule: Rule

    public init(key: String, rule: Rule) {
        self.key = key
        self.rule = rule
    }

    public var description: String {
        switch self.rule {
        case .unknownKey: "\(self.key) is not a known rate"
        case .notANumber: "\(self.key) must be a finite number"
        case .negative: "\(self.key) must be at least 0"
        case .missing: "\(self.key) is required"
        case .thresholdNotPositiveWhole: "\(self.key) must be a positive whole number"
        case .longContextWithoutThreshold: "long-context rates need \(self.key)"
        }
    }
}

extension ModelPricing {
    static let thresholdKey = "thresholdTokens"
    static let longContextKeys: Set<String> = [
        "inputAbove", "outputAbove", "cacheWriteAbove", "cacheWrite1hAbove", "cacheReadAbove",
    ]
    /// Every key a rate set can carry.
    static var rateKeys: Set<String> {
        Set(["input", "output", Self.thresholdKey] + Self.optionalRates.map(\.json))
    }

    /// Every rule `rates` breaks, keyed as the price book and the override file spell them.
    /// Empty means `init(rates:)` will accept them.
    public static func violations(in rates: [String: Double]) -> [RateViolation] {
        var violations: [RateViolation] = []
        for key in rates.keys.sorted() where !Self.rateKeys.contains(key) {
            violations.append(RateViolation(key: key, rule: .unknownKey))
        }
        for key in ["input", "output"] where rates[key] == nil {
            violations.append(RateViolation(key: key, rule: .missing))
        }
        for (key, value) in rates.sorted(by: { $0.key < $1.key }) where Self.rateKeys.contains(key) {
            if !value.isFinite {
                violations.append(RateViolation(key: key, rule: .notANumber))
            } else if key == Self.thresholdKey {
                if value <= 0 || value != value.rounded() || value >= 1e12 {
                    violations.append(RateViolation(key: key, rule: .thresholdNotPositiveWhole))
                }
            } else if value < 0 {
                violations.append(RateViolation(key: key, rule: .negative))
            }
        }
        if rates[Self.thresholdKey] == nil, rates.keys.contains(where: Self.longContextKeys.contains) {
            violations.append(RateViolation(key: Self.thresholdKey, rule: .longContextWithoutThreshold))
        }
        return violations
    }

    /// A rate set from its keys, or the first rule it breaks.
    public init(rates: [String: Double]) throws {
        if let violation = Self.violations(in: rates).first { throw violation }
        // `violations` guarantees both base rates are present.
        self.init(
            input: rates["input"] ?? 0,
            output: rates["output"] ?? 0,
            cacheWrite: rates["cacheWrite"],
            cacheWrite1h: rates["cacheWrite1h"],
            cacheRead: rates["cacheRead"],
            thresholdTokens: rates[Self.thresholdKey].map { Int($0) },
            inputAbove: rates["inputAbove"],
            outputAbove: rates["outputAbove"],
            cacheWriteAbove: rates["cacheWriteAbove"],
            cacheWrite1hAbove: rates["cacheWrite1hAbove"],
            cacheReadAbove: rates["cacheReadAbove"]
        )
    }

    /// A rate set from a JSON object. The price book takes JSON numbers only; the override file
    /// also takes numbers written as strings, which hand edits have always been allowed.
    init(json object: [String: Any], numericStrings: Bool) throws {
        var rates: [String: Double] = [:]
        for (key, raw) in object {
            guard let value = Self.number(raw, numericStrings: numericStrings) else {
                throw RateViolation(key: key, rule: Self.rateKeys.contains(key) ? .notANumber : .unknownKey)
            }
            rates[key] = value
        }
        try self.init(rates: rates)
    }

    /// The rate set as the keys `init(rates:)` reads back.
    var rateValues: [String: Double] {
        var values = ["input": self.input, "output": self.output]
        if let threshold = self.thresholdTokens { values[Self.thresholdKey] = Double(threshold) }
        for rate in Self.optionalRates {
            if let value = self[keyPath: rate.value] { values[rate.json] = value }
        }
        return values
    }

    /// Booleans also bridge to NSNumber and are rejected.
    private static func number(_ value: Any, numericStrings: Bool) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if numericStrings, let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
