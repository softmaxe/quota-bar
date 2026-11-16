// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift
//
// Rates are USD per million tokens here and divided down at lookup, which keeps them readable
// against published price lists. The rates themselves live in the price book
// (`Resources/Pricing/price-book.json`), and `RateCard` decides which apply to a day.

import CQuotaBarRust
import Foundation

public struct ModelPricing: Sendable, Equatable {
    public let input: Double
    public let output: Double
    /// Five-minute cache write, which is the TTL the published tables quote.
    public let cacheWrite: Double?
    /// One-hour cache write. nil bills it at `oneHourCacheWriteMultiplier` times the input rate,
    /// which is the ratio Anthropic publishes instead of a column of its own.
    public let cacheWrite1h: Double?
    public let cacheRead: Double?
    /// Above this many tokens in one request the long-context rates apply.
    public let thresholdTokens: Int?
    public let inputAbove: Double?
    public let outputAbove: Double?
    public let cacheWriteAbove: Double?
    public let cacheWrite1hAbove: Double?
    public let cacheReadAbove: Double?

    /// Every optional rate, paired with the key the price book spells it with. One list, so a
    /// new rate cannot reach a file without also reaching everything that reads it back.
    public static let optionalRates: [(json: String, value: KeyPath<ModelPricing, Double?>)] = [
        ("cacheWrite", \.cacheWrite),
        ("cacheWrite1h", \.cacheWrite1h),
        ("cacheRead", \.cacheRead),
        ("inputAbove", \.inputAbove),
        ("outputAbove", \.outputAbove),
        ("cacheWriteAbove", \.cacheWriteAbove),
        ("cacheWrite1hAbove", \.cacheWrite1hAbove),
        ("cacheReadAbove", \.cacheReadAbove),
    ]

    public init(
        input: Double,
        output: Double,
        cacheWrite: Double? = nil,
        cacheWrite1h: Double? = nil,
        cacheRead: Double? = nil,
        thresholdTokens: Int? = nil,
        inputAbove: Double? = nil,
        outputAbove: Double? = nil,
        cacheWriteAbove: Double? = nil,
        cacheWrite1hAbove: Double? = nil,
        cacheReadAbove: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.thresholdTokens = thresholdTokens
        self.inputAbove = inputAbove
        self.outputAbove = outputAbove
        self.cacheWriteAbove = cacheWriteAbove
        self.cacheWrite1hAbove = cacheWrite1hAbove
        self.cacheReadAbove = cacheReadAbove
    }

    /// Every rate multiplied by `factor`, with the long-context threshold unchanged. Codex and
    /// Claude Fast are priced this way from the Standard row. Returns nil if scaling overflows.
    public func scaled(by factor: Double) -> ModelPricing? {
        guard factor.isFinite, factor >= 0, Self.violations(in: self.rateValues).isEmpty else { return nil }
        let scaled = ModelPricing(
            input: self.input * factor,
            output: self.output * factor,
            cacheWrite: self.cacheWrite.map { $0 * factor },
            cacheWrite1h: self.cacheWrite1h.map { $0 * factor },
            cacheRead: self.cacheRead.map { $0 * factor },
            thresholdTokens: self.thresholdTokens,
            inputAbove: self.inputAbove.map { $0 * factor },
            outputAbove: self.outputAbove.map { $0 * factor },
            cacheWriteAbove: self.cacheWriteAbove.map { $0 * factor },
            cacheWrite1hAbove: self.cacheWrite1hAbove.map { $0 * factor },
            cacheReadAbove: self.cacheReadAbove.map { $0 * factor }
        )
        return Self.violations(in: scaled.rateValues).isEmpty ? scaled : nil
    }

    /// Anthropic's published ratio between a one-hour cache write and the base input rate.
    /// Used only when no explicit one-hour rate is set.
    public static let oneHourCacheWriteMultiplier = 2.0

    /// The one-hour cache-write rate actually billed, derived from the input rate when the
    /// rates do not state one.
    public func cacheWrite1hRate(longContext: Bool) -> Double {
        var pricing = self.rustPricing
        return qb_pricing_cache_write_1h_rate(&pricing, longContext ? 1 : 0)
    }

    /// Cost in USD for one bucket of tokens, or nil when rates or the amount are invalid.
    public func cost(for totals: TokenTotals, longContext: Bool) -> Double? {
        var pricing = self.rustPricing
        var tokens = QBPricingTokens(
            input: Int64(totals.input), output: Int64(totals.output),
            cache_write: Int64(totals.cacheWrite), cache_write_1h: Int64(totals.cacheWrite1h),
            cache_read: Int64(totals.cacheRead)
        )
        var cost = 0.0
        return qb_pricing_cost(&pricing, &tokens, longContext ? 1 : 0, &cost) != 0 ? cost : nil
    }

    /// The fixed-width ABI keeps absent rates distinct from stated zero rates.
    private var rustPricing: QBModelPricing {
        var present: UInt32 = 0
        if self.cacheWrite != nil { present |= 1 << 0 }
        if self.cacheWrite1h != nil { present |= 1 << 1 }
        if self.cacheRead != nil { present |= 1 << 2 }
        if self.inputAbove != nil { present |= 1 << 3 }
        if self.outputAbove != nil { present |= 1 << 4 }
        if self.cacheWriteAbove != nil { present |= 1 << 5 }
        if self.cacheWrite1hAbove != nil { present |= 1 << 6 }
        if self.cacheReadAbove != nil { present |= 1 << 7 }
        if self.thresholdTokens != nil { present |= 1 << 8 }
        return QBModelPricing(
            input: self.input, output: self.output,
            cache_write: self.cacheWrite ?? 0, cache_write_1h: self.cacheWrite1h ?? 0,
            cache_read: self.cacheRead ?? 0, input_above: self.inputAbove ?? 0,
            output_above: self.outputAbove ?? 0, cache_write_above: self.cacheWriteAbove ?? 0,
            cache_write_1h_above: self.cacheWrite1hAbove ?? 0, cache_read_above: self.cacheReadAbove ?? 0,
            threshold_tokens: Int64(self.thresholdTokens ?? 0), present: present
        )
    }
}

public enum CostPricing {
    /// Model name recorded for tokens whose model could not be determined. Never priced.
    public static let unknownModel = "unknown"

    public enum CodexServiceTier: Sendable, Equatable {
        case standard
        case fast

        static func parse(_ raw: String?) -> Self {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "priority", "fast": .fast
            default: .standard
            }
        }

        var isFast: Bool { self == .fast }
    }
}

/// Strips the vendor decorations a log puts around a model name. This part of naming a model does
/// not depend on the price book, and scanners run it for every usage line of a log that names a
/// handful of models, so each raw name is worked out once instead of through several regexes per
/// line. Resolving aliases is left to the rate card's book.
enum ModelNames {
    private static let codex = Memo()
    private static let claude = Memo()

    static func stripped(_ raw: String, provider: Provider) -> String {
        switch provider {
        case .codex: Self.codex.value(for: raw, compute: Self.strippedCodex)
        case .claude: Self.claude.value(for: raw, compute: Self.strippedClaude)
        }
    }

    /// `openai/gpt-5.1-2026-01-01` -> `gpt-5.1`.
    private static func strippedCodex(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return Self.strippingDateSuffix(name)
    }

    /// `anthropic.claude-opus-5-v1:0` -> `claude-opus-5`, `claude-opus-5-20260101` -> `claude-opus-5`,
    /// `openrouter/z-ai/glm-5` -> `glm-5`.
    private static func strippedClaude(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Claude Code pointed at a router names models by path; the model is the last segment,
        // which is also the key models.dev prices it under.
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.replacingOccurrences(of: #"^(?:(?:us|eu|apac|global)\.)?anthropic\."#, with: "", options: .regularExpression)
        let versionSuffix = name.hasPrefix("claude-") ? #"-v\d+(?::\d+)?$"# : #"-v\d+:\d+$"#
        if let range = name.range(of: versionSuffix, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if name.hasPrefix("claude-") {
            name = name.replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "-", options: .regularExpression)
        }
        return Self.strippingDateSuffix(name)
    }

    private static func strippingDateSuffix(_ name: String) -> String {
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        if let range = name.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    private final class Memo: @unchecked Sendable {
        /// Unbounded input would make this a leak; past the cap names are computed without caching.
        private static let capacity = 4096
        private let lock = NSLock()
        private var names: [String: String] = [:]

        func value(for raw: String, compute: (String) -> String) -> String {
            self.lock.lock()
            let cached = self.names[raw]
            self.lock.unlock()
            if let cached { return cached }
            let name = compute(raw)
            self.lock.lock()
            if self.names.count < Self.capacity { self.names[raw] = name }
            self.lock.unlock()
            return name
        }
    }
}
