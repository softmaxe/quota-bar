// The published rates every cost is derived from, kept as data in
// `Resources/Pricing/price-book.json` rather than as Swift literals so a price change is a data
// edit that the validation below checks before it can ship.
//
// Each model carries a list of dated periods. A usage day is priced by the last period that
// started on or before it, so a price change or the end of a promotion is a new period, and
// history keeps the rates that were in force on the day the tokens were spent.

import Foundation

public struct PriceBook: Sendable {
    /// One model's rates over time.
    public struct Model: Sendable, Equatable {
        /// Normalized model name, as scanners store it.
        public let id: String
        /// Other names the provider accepts for the same model. They resolve to `id` before
        /// anything is stored, so both names aggregate as one model.
        public let aliases: [String]
        /// Listed in the pricing settings even before it appears in local logs.
        public let showInSettings: Bool
        /// No longer on the provider's price list; kept so older usage stays priced.
        public let retired: Bool
        public let source: String?
        public let checkedAt: String?
        public let note: String?
        /// Ascending by start day. The first period has no start and covers everything before
        /// the second.
        public let periods: [Period]
    }

    public struct Period: Sendable, Equatable {
        /// First local day (`yyyy-MM-dd`) these rates apply to; nil for the opening period.
        public let from: String?
        public let rates: ModelPricing
        /// Codex Fast bills every rate of the period at this multiple. nil means the model has
        /// no Fast tier in this period, so Fast usage of it stays unpriced.
        public let fastMultiplier: Double?
    }

    public struct ProviderSection: Sendable, Equatable {
        public let source: String
        /// When the provider's price list was last compared against this book.
        public let checkedAt: String
        public let models: [Model]
    }

    public static let schemaVersion = 1

    private let sections: [Provider: ProviderSection]
    private let modelIndex: [Provider: [String: Int]]
    private let aliasIndex: [Provider: [String: String]]

    // MARK: - Loading

    /// The book shipped inside the app. A book that fails validation is a build defect the test
    /// suite catches; at runtime it degrades to an empty book so usage is still counted, unpriced.
    public static let bundled: PriceBook = {
        do {
            guard let url = CoreResources.bundle.url(
                forResource: "price-book",
                withExtension: "json",
                subdirectory: "Pricing"
            ) else {
                throw PriceBookError.invalid("price-book.json is missing from the app bundle")
            }
            return try PriceBook(data: Data(contentsOf: url))
        } catch {
            Log.ui.error("Could not load the price book: \(error.localizedDescription, privacy: .public)")
            return PriceBook(sections: [:])
        }
    }()

    public init(data: Data) throws {
        let root = try Self.object(
            try? JSONSerialization.jsonObject(with: data),
            at: "root",
            allowed: ["schemaVersion", "providers"]
        )
        guard (root["schemaVersion"] as? NSNumber)?.intValue == Self.schemaVersion else {
            throw PriceBookError.invalid("schemaVersion must be \(Self.schemaVersion)")
        }
        let providers = try Self.object(root["providers"], at: "providers", allowed: nil)

        var sections: [Provider: ProviderSection] = [:]
        for (key, value) in providers {
            guard let provider = Provider(rawValue: key) else {
                throw PriceBookError.invalid("providers.\(key) is not a known provider")
            }
            sections[provider] = try Self.section(value, at: "providers.\(key)")
        }
        self.init(sections: sections)
        try self.validateNames()
    }

    private init(sections: [Provider: ProviderSection]) {
        self.sections = sections
        var modelIndex: [Provider: [String: Int]] = [:]
        var aliasIndex: [Provider: [String: String]] = [:]
        for (provider, section) in sections {
            for (offset, model) in section.models.enumerated() {
                modelIndex[provider, default: [:]][model.id] = offset
                for alias in model.aliases { aliasIndex[provider, default: [:]][alias] = model.id }
            }
        }
        self.modelIndex = modelIndex
        self.aliasIndex = aliasIndex
    }

    // MARK: - Lookup

    public func section(for provider: Provider) -> ProviderSection? {
        self.sections[provider]
    }

    /// Every model of a provider, in the order the book lists them.
    public func models(for provider: Provider) -> [Model] {
        self.sections[provider]?.models ?? []
    }

    public func model(_ id: String, provider: Provider) -> Model? {
        guard let offset = self.modelIndex[provider]?[id] else { return nil }
        return self.sections[provider]?.models[offset]
    }

    /// The model id an alias stands for, or the name itself when it is not an alias.
    public func canonicalID(for name: String, provider: Provider) -> String {
        self.aliasIndex[provider]?[name] ?? name
    }

    /// Rates in force for `id` on `day` (`yyyy-MM-dd`), or nil when the book does not price it.
    public func rates(for id: String, provider: Provider, day: String, fast: Bool = false) -> ModelPricing? {
        guard let model = self.model(id, provider: provider),
              let period = model.periods.last(where: { ($0.from ?? "") <= day }) else { return nil }
        guard fast else { return period.rates }
        return period.fastMultiplier.map { period.rates.scaled(by: $0) }
    }

    // MARK: - Parsing

    private static func section(_ value: Any?, at path: String) throws -> ProviderSection {
        let object = try Self.object(value, at: path, allowed: ["source", "checkedAt", "models"])
        guard let models = object["models"] as? [Any], !models.isEmpty else {
            throw PriceBookError.invalid("\(path).models must be a non-empty array")
        }
        return ProviderSection(
            source: try Self.string(object["source"], at: "\(path).source"),
            checkedAt: try Self.day(object["checkedAt"], at: "\(path).checkedAt"),
            models: try models.enumerated().map { try Self.model($1, at: "\(path).models[\($0)]") }
        )
    }

    private static func model(_ value: Any?, at path: String) throws -> Model {
        let object = try Self.object(
            value,
            at: path,
            allowed: ["id", "aliases", "showInSettings", "retired", "source", "checkedAt", "note", "periods"]
        )
        let id = try Self.name(object["id"], at: "\(path).id")
        let path = "\(path) (\(id))"
        if object["aliases"] != nil, !(object["aliases"] is [Any]) {
            throw PriceBookError.invalid("\(path).aliases must be an array")
        }
        let aliases = try (object["aliases"] as? [Any] ?? []).enumerated().map {
            try Self.name($1, at: "\(path).aliases[\($0)]")
        }
        guard let rawPeriods = object["periods"] as? [Any], !rawPeriods.isEmpty else {
            throw PriceBookError.invalid("\(path).periods must be a non-empty array")
        }
        let periods = try rawPeriods.enumerated().map { try Self.period($1, at: "\(path).periods[\($0)]") }
        if periods[0].from != nil {
            throw PriceBookError.invalid("\(path).periods[0] must not have a from day")
        }
        for index in periods.indices.dropFirst() {
            guard let from = periods[index].from else {
                throw PriceBookError.invalid("\(path).periods[\(index)] needs a from day")
            }
            if let previous = periods[index - 1].from, from <= previous {
                throw PriceBookError.invalid("\(path).periods must be in ascending from order")
            }
        }
        return Model(
            id: id,
            aliases: aliases,
            showInSettings: try Self.flag(object["showInSettings"], at: "\(path).showInSettings"),
            retired: try Self.flag(object["retired"], at: "\(path).retired"),
            source: try object["source"].map { try Self.string($0, at: "\(path).source") },
            checkedAt: try object["checkedAt"].map { try Self.day($0, at: "\(path).checkedAt") },
            note: try object["note"].map { try Self.string($0, at: "\(path).note") },
            periods: periods
        )
    }

    private static func period(_ value: Any?, at path: String) throws -> Period {
        let object = try Self.object(value, at: path, allowed: ["from", "rates", "fastMultiplier"])
        var fastMultiplier: Double?
        if let raw = object["fastMultiplier"] {
            guard let multiplier = Self.number(raw), multiplier > 0 else {
                throw PriceBookError.invalid("\(path).fastMultiplier must be a positive number")
            }
            fastMultiplier = multiplier
        }
        return Period(
            from: try object["from"].map { try Self.day($0, at: "\(path).from") },
            rates: try Self.rates(object["rates"], at: "\(path).rates"),
            fastMultiplier: fastMultiplier
        )
    }

    /// Rates use the same keys as the user override file, in USD per million tokens.
    private static func rates(_ value: Any?, at path: String) throws -> ModelPricing {
        let optional = ModelPricing.optionalRates.map(\.json)
        let object = try Self.object(
            value,
            at: path,
            allowed: Set(["input", "output", "thresholdTokens"] + optional)
        )
        func rate(_ key: String) throws -> Double? {
            guard let raw = object[key] else { return nil }
            guard let rate = Self.number(raw), rate >= 0 else {
                throw PriceBookError.invalid("\(path).\(key) must be a finite number of at least 0")
            }
            return rate
        }
        guard let input = try rate("input"), let output = try rate("output") else {
            throw PriceBookError.invalid("\(path) needs both input and output")
        }
        var threshold: Int?
        if let raw = object["thresholdTokens"] {
            guard let value = Self.number(raw), value > 0, value == value.rounded(), value < 1e12 else {
                throw PriceBookError.invalid("\(path).thresholdTokens must be a positive whole number")
            }
            threshold = Int(value)
        }
        let above = ["inputAbove", "outputAbove", "cacheWriteAbove", "cacheWrite1hAbove", "cacheReadAbove"]
        if threshold == nil, above.contains(where: { object[$0] != nil }) {
            throw PriceBookError.invalid("\(path) sets long-context rates without thresholdTokens")
        }
        return ModelPricing(
            input: input,
            output: output,
            cacheWrite: try rate("cacheWrite"),
            cacheWrite1h: try rate("cacheWrite1h"),
            cacheRead: try rate("cacheRead"),
            thresholdTokens: threshold,
            inputAbove: try rate("inputAbove"),
            outputAbove: try rate("outputAbove"),
            cacheWriteAbove: try rate("cacheWriteAbove"),
            cacheWrite1hAbove: try rate("cacheWrite1hAbove"),
            cacheReadAbove: try rate("cacheReadAbove")
        )
    }

    /// Ids and aliases must each name one model, and an alias must never shadow a real id.
    private func validateNames() throws {
        for (provider, section) in self.sections {
            var seen: Set<String> = []
            for name in section.models.map(\.id) + section.models.flatMap(\.aliases) {
                guard seen.insert(name).inserted else {
                    throw PriceBookError.invalid("providers.\(provider.rawValue) names \(name) more than once")
                }
            }
        }
    }

    // MARK: - JSON helpers

    /// A JSON object whose keys are all in `allowed`, so a misspelt key fails loudly instead of
    /// silently dropping a rate.
    private static func object(_ value: Any?, at path: String, allowed: Set<String>?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw PriceBookError.invalid("\(path) must be a JSON object")
        }
        if let allowed, let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw PriceBookError.invalid("\(path) has an unknown key: \(unknown)")
        }
        return object
    }

    private static func string(_ value: Any?, at path: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw PriceBookError.invalid("\(path) must be a non-empty string")
        }
        return string
    }

    /// A model name as the scanners store it: trimmed and lowercased.
    private static func name(_ value: Any?, at path: String) throws -> String {
        let name = try Self.string(value, at: path)
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw PriceBookError.invalid("\(path) must be lowercase with no surrounding whitespace")
        }
        return name
    }

    private static func day(_ value: Any?, at path: String) throws -> String {
        let day = try Self.string(value, at: path)
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw PriceBookError.invalid("\(path) must be a yyyy-MM-dd day")
        }
        return day
    }

    private static func flag(_ value: Any?, at path: String) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw PriceBookError.invalid("\(path) must be true or false")
        }
        return number.boolValue
    }

    /// JSON numbers only; booleans also bridge to NSNumber and are rejected.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

public enum PriceBookError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): "Invalid price book: \(message)"
        }
    }
}
