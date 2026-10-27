// Rates for the models the price book does not cover. The book is kept by hand for Claude and
// OpenAI models only; every other model a Usage source reports is estimated from models.dev.
//
// models.dev publishes today's rates only, so the history comes from this machine: each fetch is
// folded into a local cache, and a model whose rates changed opens a new period on the day the
// change was first seen.

import Foundation

public struct ThirdPartyRates: Sendable, Equatable {
    public struct Period: Sendable, Equatable {
        /// First local day (`yyyy-MM-dd`) these rates apply to; nil for the opening period, which
        /// covers every day before the next one.
        public let from: String?
        public let rates: ModelPricing

        public init(from: String?, rates: ModelPricing) {
            self.from = from
            self.rates = rates
        }
    }

    /// Keyed by `ThirdPartyRates.key(for:)`. Periods ascend by start day.
    public let models: [String: [Period]]
    /// When models.dev was last read successfully; nil when it never was.
    public let fetchedAt: Date?

    public static let empty = ThirdPartyRates(models: [:], fetchedAt: nil)

    public init(models: [String: [Period]], fetchedAt: Date?) {
        self.models = models
        self.fetchedAt = fetchedAt
    }

    /// One opening period per model.
    public init(current: [String: ModelPricing], fetchedAt: Date? = nil) {
        self.init(
            models: Dictionary(current.map {
                (Self.key(for: $0.key), [Period(from: nil, rates: $0.value)])
            }, uniquingKeysWith: { first, _ in first }),
            fetchedAt: fetchedAt
        )
    }

    /// Rates in force for a model on `day`, or nil when models.dev never priced it or the model
    /// is one the price book is kept for.
    public func rates(for name: String, day: String) -> ModelPricing? {
        self.periods(for: name)?.last(where: { ($0.from ?? "") <= day })?.rates
    }

    /// Whether models.dev has priced this model at all.
    public func prices(_ name: String) -> Bool {
        self.periods(for: name) != nil
    }

    /// The periods a model is priced by. A name models.dev does not list under its own spelling
    /// falls back to the model a region suffix decorates, so `deepseek-v4.1-flash-sg` is priced as
    /// `deepseek-v4.1-flash`. A listing under the full name wins, since it may be a regional price.
    private func periods(for name: String) -> [Period]? {
        guard Self.isThirdParty(name) else { return nil }
        let key = Self.key(for: name)
        if let periods = self.models[key] { return periods }
        return Self.strippingRegion(key).flatMap { self.models[$0] }
    }

    /// Region and deployment tags that endpoints append to a model's name without making it a
    /// different model. Tags such as `-fast`, `-flex`, or `:thinking` name different offers at
    /// different prices, so they are not on this list.
    private static let regionSuffix =
        #"[-_@](sg|us|eu|cn|jp|kr|uk|in|au|ca|de|fr|br|hk|tw|global|intl|apac|emea)$"#

    /// The name without a trailing region tag, or nil when it has none.
    private static func strippingRegion(_ key: String) -> String? {
        guard let range = key.range(of: Self.regionSuffix, options: .regularExpression),
              range.lowerBound > key.startIndex
        else { return nil }
        return String(key[..<range.lowerBound])
    }

    /// This fetch folded into the rates already kept. A model whose rates changed opens a period
    /// on `day`, so earlier days keep the rates they had. A model models.dev no longer lists
    /// keeps its last rates, so its recorded usage stays priced.
    public func merging(_ fetched: [String: ModelPricing], on day: String, at date: Date) -> ThirdPartyRates {
        var models = self.models
        for (name, rates) in fetched {
            let key = Self.key(for: name)
            guard var periods = models[key], let last = periods.last else {
                models[key] = [Period(from: nil, rates: rates)]
                continue
            }
            guard last.rates != rates else { continue }
            if let from = last.from, from >= day {
                // A second change on the same day replaces the first.
                periods[periods.count - 1] = Period(from: from, rates: rates)
            } else {
                periods.append(Period(from: day, rates: rates))
            }
            models[key] = periods
        }
        return ThirdPartyRates(models: models, fetchedAt: date)
    }

    /// The name a model is kept under: lowercased, after its last `/`, so `openrouter/z-ai/GLM-5.3`
    /// and `glm-5.3` are one model. A `:free` or `:latest` tag is kept, since it names a
    /// different offer.
    package static func key(for name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = lowered.lastIndex(of: "/") else { return lowered }
        return String(lowered[lowered.index(after: slash)...])
    }

    /// Claude and OpenAI models are priced by the price book alone. A copy of one on a reseller's
    /// list is not the vendor's price, so models.dev never prices them, even before the book
    /// lists a new one. Resellers spell them many ways (`openai-o3`, `anthropic--claude-3-opus`,
    /// `us.anthropic.claude-…`), so any name mentioning `claude` or `gpt-` is refused, along with
    /// the vendor prefixes and OpenAI's bare `o<digit>` and `codex-` names.
    package static func isThirdParty(_ name: String) -> Bool {
        let key = Self.key(for: name)
        if key.contains("claude") || key.contains("gpt-") { return false }
        if ["chatgpt-", "codex-"].contains(where: key.hasPrefix) { return false }
        let official = #"^((us|eu|apac|global|jp|au)\.)?(openai|anthropic)[-._]|^o\d+(-|$)"#
        return key.range(of: official, options: .regularExpression) == nil
    }
}

// MARK: - The local cache

/// Where third-party rates come from on this machine: the cache file, whether pricing from it is
/// on, and how models.dev is downloaded.
public struct ModelsDevPricing: Sendable {
    public let cacheURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let download: @Sendable () async throws -> Data

    /// `~/Library/Application Support/QuotaBar/third-party-rates.json`.
    public static var defaultCacheURL: URL {
        AppSupport.directory.appendingPathComponent("third-party-rates.json")
    }

    public init(
        cacheURL: URL = ModelsDevPricing.defaultCacheURL,
        isEnabled: @escaping @Sendable () -> Bool,
        download: @escaping @Sendable () async throws -> Data = { try await ModelsDevCatalog.download() }
    ) {
        self.cacheURL = cacheURL
        self.isEnabled = isEnabled
        self.download = download
    }

    /// The app's own: the setting in the standard defaults and the real download.
    public static var live: ModelsDevPricing {
        ModelsDevPricing(isEnabled: { SettingsStore.isModelsDevPricingEnabled() })
    }

    public var enabled: Bool { self.isEnabled() }

    /// The rates pricing may use: the cached ones, or none while the setting is off.
    public func rates() -> ThirdPartyRates {
        self.isEnabled() ? self.cached() : .empty
    }

    /// Downloads models.dev and folds it into the cache. Returns the new rates, or throws and
    /// leaves the cache as it was.
    package func fetch(into current: ThirdPartyRates, now: Date) async throws -> ThirdPartyRates {
        let fetched = try ModelsDevCatalog.rates(from: try await self.download())
        guard !fetched.isEmpty else { throw ModelsDevCatalog.Error.empty }
        // The setting may have been turned off while the download was in flight.
        guard self.isEnabled() else { throw CancellationError() }
        let merged = current.merging(fetched, on: DayKey.make(from: now), at: now)
        try self.save(merged)
        return merged
    }

    /// What the cache file holds whatever the setting. A missing or unreadable file holds
    /// nothing, and a model whose entry does not read is dropped alone.
    public func cached() -> ThirdPartyRates {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["schemaVersion"] as? NSNumber)?.intValue == Self.schemaVersion,
              let rawModels = root["models"] as? [String: Any] else { return .empty }
        var models: [String: [ThirdPartyRates.Period]] = [:]
        for (name, value) in rawModels {
            guard let rawPeriods = value as? [[String: Any]], !rawPeriods.isEmpty else { continue }
            let periods = rawPeriods.compactMap { period -> ThirdPartyRates.Period? in
                guard let rates = period["rates"] as? [String: Any],
                      let pricing = try? ModelPricing(json: rates) else { return nil }
                return ThirdPartyRates.Period(from: period["from"] as? String, rates: pricing)
            }
            if periods.count == rawPeriods.count { models[name] = periods }
        }
        let fetchedAt = (root["fetchedAt"] as? String).flatMap(ISO8601.parse)
        return ThirdPartyRates(models: models, fetchedAt: fetchedAt)
    }

    package func save(_ rates: ThirdPartyRates) throws {
        var models: [String: Any] = [:]
        for (name, periods) in rates.models {
            models[name] = periods.map { period -> [String: Any] in
                var entry: [String: Any] = ["rates": period.rates.rateValues]
                if let from = period.from { entry["from"] = from }
                return entry
            }
        }
        var root: [String: Any] = ["schemaVersion": Self.schemaVersion, "models": models]
        if let fetchedAt = rates.fetchedAt {
            root["fetchedAt"] = ISO8601DateFormatter().string(from: fetchedAt)
        }
        try FileManager.default.createDirectory(
            at: self.cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: self.cacheURL, options: .atomic)
    }

    private static let schemaVersion = 1
}
