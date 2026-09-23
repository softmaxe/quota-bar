// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift
//
// Rates are USD per million tokens here and divided down at lookup, which keeps them readable
// against published price lists. The rates themselves live in the price book
// (`Resources/Pricing/price-book.json`); standard resolution uses the user override, then the
// book's period for the usage day. Fast resolution uses the book alone.

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

    /// Every optional rate, paired with the key the override file spells it with. One list, so a
    /// new rate cannot reach the file without also reaching everything that reads it back.
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

    /// Every rate multiplied by `factor`, with the long-context threshold unchanged. Codex Fast
    /// is priced this way from the Standard row.
    public func scaled(by factor: Double) -> ModelPricing {
        ModelPricing(
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
    }

    /// Anthropic's published ratio between a one-hour cache write and the base input rate.
    /// Used only when no explicit one-hour rate is set.
    public static let oneHourCacheWriteMultiplier = 2.0

    /// The one-hour cache-write rate actually billed, derived from the input rate when the
    /// table (or the user's override) does not state one.
    public func cacheWrite1hRate(longContext: Bool) -> Double {
        let inputRate = (longContext ? self.inputAbove : nil) ?? self.input
        if let stated = (longContext ? self.cacheWrite1hAbove : nil) ?? self.cacheWrite1h { return stated }
        return inputRate * Self.oneHourCacheWriteMultiplier
    }

    /// Cost in USD for one bucket of tokens, at either the base or the long-context tier.
    public func cost(for totals: TokenTotals, longContext: Bool) -> Double {
        let million = 1_000_000.0
        let inputRate = (longContext ? self.inputAbove : nil) ?? self.input
        let outputRate = (longContext ? self.outputAbove : nil) ?? self.output
        // A model without its own cache rates bills cached tokens at the full input rate.
        let cacheWriteRate = (longContext ? self.cacheWriteAbove : nil) ?? self.cacheWrite ?? inputRate
        let cacheReadRate = (longContext ? self.cacheReadAbove : nil) ?? self.cacheRead ?? inputRate

        // Anthropic prices a one-hour cache write at twice the input rate, against 1.25x for the
        // five-minute default. The table's cache-write column is the five-minute rate, so unless
        // a one-hour rate is stated the longer TTL is derived the way Anthropic publishes it.
        let write1h = Double(min(totals.cacheWrite1h, totals.cacheWrite))
        let write5m = Double(totals.cacheWrite) - write1h

        return (Double(totals.input) * inputRate
            + Double(totals.output) * outputRate
            + write5m * cacheWriteRate
            + write1h * self.cacheWrite1hRate(longContext: longContext)
            + Double(totals.cacheRead) * cacheReadRate) / million
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

    // MARK: - Normalization

    /// `openai/gpt-5.1-2026-01-01` -> `gpt-5.1`. Aliases the price book lists, such as bare
    /// `gpt-5.6` for `gpt-5.6-sol`, resolve to the model they stand for.
    public static func normalizeCodexModel(_ raw: String) -> String {
        NormalizedModelNames.codex.value(for: raw, compute: Self.computeNormalizedCodexModel)
    }

    private static func computeNormalizedCodexModel(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return PriceBook.bundled.canonicalID(for: Self.strippingDateSuffix(name), provider: .codex)
    }

    /// `anthropic.claude-opus-5-v1:0` -> `claude-opus-5`, `claude-opus-5-20260101` -> `claude-opus-5`.
    public static func normalizeClaudeModel(_ raw: String) -> String {
        NormalizedModelNames.claude.value(for: raw, compute: Self.computeNormalizedClaudeModel)
    }

    private static func computeNormalizedClaudeModel(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["anthropic.", "anthropic/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if let range = name.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        return PriceBook.bundled.canonicalID(for: Self.strippingDateSuffix(name), provider: .claude)
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

    public static func normalize(_ raw: String, provider: Provider) -> String {
        switch provider {
        case .codex: self.normalizeCodexModel(raw)
        case .claude: self.normalizeClaudeModel(raw)
        }
    }

    // MARK: - Lookup

    /// Resolves a model's rates on `day` (`yyyy-MM-dd`, today when nil). `overlay` carries the
    /// user's overrides, which apply to every day; the book supplies the dated rates beneath them.
    public static func pricing(
        for rawModel: String,
        provider: Provider,
        day: String? = nil,
        overlay: PricingOverlay? = nil,
        codexServiceTier: CodexServiceTier = .standard,
        book: PriceBook = .bundled
    ) -> ModelPricing? {
        self.pricing(
            forNormalizedModel: self.normalize(rawModel, provider: provider),
            provider: provider,
            day: day ?? DayKey.today(),
            overlay: overlay,
            codexServiceTier: codexServiceTier,
            book: book
        )
    }

    /// Resolves rates for a model that the scanner has already normalized.
    static func pricing(
        forNormalizedModel name: String,
        provider: Provider,
        day: String,
        overlay: PricingOverlay? = nil,
        codexServiceTier: CodexServiceTier = .standard,
        book: PriceBook = .bundled
    ) -> ModelPricing? {
        guard name != Self.unknownModel, !name.isEmpty else { return nil }
        // Fast is a multiple of the book's Standard row; an override states Standard rates only,
        // so it cannot say what Fast costs, and an unknown Fast model stays unpriced.
        if provider == .codex, codexServiceTier == .fast {
            return book.rates(for: name, provider: provider, day: day, fast: true)
        }
        if let userOverride = overlay?.userOverrides[name] { return userOverride }
        return book.rates(for: name, provider: provider, day: day)
    }

    static func isLongContext(totals: TokenTotals, pricing: ModelPricing?) -> Bool {
        guard let threshold = pricing?.thresholdTokens else { return false }
        let measured = totals.input + totals.cacheRead + totals.cacheWrite
        return measured > threshold
    }

    /// Whether one request's input and cache tokens cross the model's long-context threshold.
    public static func isLongContext(
        totals: TokenTotals,
        model: String,
        provider: Provider,
        day: String? = nil,
        overlay: PricingOverlay? = nil,
        codexServiceTier: CodexServiceTier = .standard,
        book: PriceBook = .bundled
    ) -> Bool {
        let pricing = self.pricing(
            for: model,
            provider: provider,
            day: day,
            overlay: overlay,
            codexServiceTier: codexServiceTier,
            book: book
        )
        return self.isLongContext(totals: totals, pricing: pricing)
    }

    /// Cost in USD, or nil when the model has no price so its tokens stay uncounted.
    public static func cost(
        totals: TokenTotals,
        model: String,
        provider: Provider,
        longContext: Bool,
        day: String? = nil,
        overlay: PricingOverlay? = nil,
        codexServiceTier: CodexServiceTier = .standard,
        book: PriceBook = .bundled
    ) -> Double? {
        guard let pricing = self.pricing(
            for: model,
            provider: provider,
            day: day,
            overlay: overlay,
            codexServiceTier: codexServiceTier,
            book: book
        ) else {
            return nil
        }
        return pricing.cost(for: totals, longContext: longContext)
    }
}

/// Scanners normalize the model of every usage line, and a log names only a handful of models.
/// Normalization is pure, so each raw name is worked out once instead of through several regexes
/// per line.
private final class NormalizedModelNames: @unchecked Sendable {
    static let codex = NormalizedModelNames()
    static let claude = NormalizedModelNames()

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
