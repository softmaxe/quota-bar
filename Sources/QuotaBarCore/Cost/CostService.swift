import Foundation

public struct ModelUsageTotal: Sendable, Equatable {
    public let model: String
    public let tokens: Int

    public init(model: String, tokens: Int) {
        self.model = model
        self.tokens = tokens
    }
}

/// Owns the persistent usage store and produces cost snapshots. An actor because the SQLite connection is
/// single-writer and scans run off the main thread.
public actor CostService {
    private var cache: CostCache?
    /// The rates of the current refresh. nil until the override file is next read.
    private var rateCard: RateCard?
    /// What a dropped rate card is rebuilt from.
    private var book: PriceBook
    private let overrideFile: OverrideFile
    private var openCodeStatus: OpenCodeScanStatus = .idle
    private var piAgentStatus: PiAgentScanStatus = .idle
    /// The Pi Agent session files the store already reflects, so an unchanged directory is not
    /// re-read on every Codex refresh.
    private var piAgentSessions: PiAgentLogScanner.SessionSnapshot?
    /// Readable without the actor so `CostUsageReader` can open the same file on a connection
    /// of its own rather than queueing behind a scan.
    public nonisolated let databaseURL: URL
    private let env: [String: String]

    /// `rateCard` pins the rates until `invalidatePricing`; tests use it to keep prices fixed. Its
    /// book, the shipped one when none is pinned, is what `overrideFile` is laid over after that.
    public init(
        databaseURL: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        rateCard: RateCard? = nil,
        overrideFile: OverrideFile = OverrideFile()
    ) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
        self.env = env
        self.rateCard = rateCard
        self.book = rateCard?.book ?? .bundled
        self.overrideFile = overrideFile
    }

    /// `~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite`.
    public static var defaultDatabaseURL: URL {
        CostDatabaseLocation.defaultURL
    }

    public func refresh(_ provider: Provider) async -> CostSnapshot? {
        do {
            let cache = try self.openCache()
            // One rate card for the whole refresh, so the scan and the pricing never disagree.
            let rateCard = self.currentRateCard()

            let started = Date()
            let touched = try self.scan(provider, cache: cache, rateCard: rateCard)
            let elapsed = Date().timeIntervalSince(started)
            if touched > 0 {
                Log.ui.info(
                    "\(provider.rawValue, privacy: .public) cost scan: \(touched) files in \(String(format: "%.1f", elapsed))s"
                )
            }

            return try CostAggregator.snapshot(
                provider: provider,
                cache: cache,
                rateCard: rateCard
            )
        } catch {
            Log.ui.error(
                "\(provider.rawValue, privacy: .public) cost scan failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Models seen in local logs with their cumulative token totals, most-used first.
    public func knownModelUsage(provider: Provider) -> [ModelUsageTotal] {
        CostUsageReader.knownModelUsage(provider: provider, databaseURL: self.databaseURL)
    }

    public func currentOpenCodeScanStatus() -> OpenCodeScanStatus {
        self.openCodeStatus
    }

    public func currentPiAgentScanStatus() -> PiAgentScanStatus {
        self.piAgentStatus
    }

    /// Drops the rate card so the next refresh reads the override file again. Cost is derived
    /// when it is read, so that refresh reprices all recorded usage at the new rates.
    public func invalidatePricing() {
        self.rateCard = nil
    }

    /// Replaces the rate card outright. The app rereads the override file instead
    /// (`invalidatePricing`); this exists so tests can move prices without touching the file.
    public func useRateCard(_ rateCard: RateCard) {
        self.rateCard = rateCard
        self.book = rateCard.book
    }

    private func openCache() throws -> CostCache {
        if let cache = self.cache { return cache }
        if self.databaseURL == Self.defaultDatabaseURL {
            try CostDatabaseLocation.migrateIfNeeded(from: CostDatabaseLocation.legacyURL, to: self.databaseURL)
        }
        let cache = try CostCache(path: self.databaseURL)
        self.cache = cache
        return cache
    }

    /// Read from disk once, then again only after `invalidatePricing`.
    private func currentRateCard() -> RateCard {
        if let rateCard = self.rateCard { return rateCard }
        let rateCard = RateCard(book: self.book, overrides: self.overrideFile.load())
        self.rateCard = rateCard
        return rateCard
    }

    /// Which scanner reads a provider's logs. The only place that mapping is spelled out.
    private func scan(_ provider: Provider, cache: CostCache, rateCard: RateCard) throws -> Int {
        switch provider {
        case .codex:
            let codexTouched = try CodexLogScanner.scan(cache: cache, rateCard: rateCard, env: self.env)
            let openCode = OpenCodeLogScanner.scan(cache: cache, rateCard: rateCard, env: self.env)
            self.openCodeStatus = openCode.status
            if case .error = openCode.status {
                Log.ui.error("OpenCode usage scan failed; cached usage was kept")
            }
            let pi = PiAgentLogScanner.scan(
                cache: cache,
                rateCard: rateCard,
                env: self.env,
                previous: self.piAgentSessions
            )
            self.piAgentSessions = pi.sessions
            self.piAgentStatus = pi.status
            if case .error = pi.status {
                Log.ui.error("Pi Agent usage scan failed; cached usage was kept")
            }
            return codexTouched + openCode.touched + pi.touched
        case .claude:
            return try ClaudeLogScanner.scan(cache: cache, rateCard: rateCard, env: self.env)
        }
    }

}
