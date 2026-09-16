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
    private var overlay: PricingOverlay?
    private var openCodeStatus: OpenCodeScanStatus = .idle
    private var piAgentStatus: PiAgentScanStatus = .idle
    /// Readable without the actor so `CostUsageReader` can open the same file on a connection
    /// of its own rather than queueing behind a scan.
    public nonisolated let databaseURL: URL
    private let env: [String: String]

    /// `pricingOverlay` pins the price layers instead of loading them; tests use it to stay offline.
    public init(
        databaseURL: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        pricingOverlay: PricingOverlay? = nil
    ) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
        self.env = env
        self.overlay = pricingOverlay
    }

    /// `~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite`.
    public static var defaultDatabaseURL: URL {
        CostDatabaseLocation.defaultURL
    }

    public func refresh(_ provider: Provider) async -> CostSnapshot? {
        do {
            let cache = try self.openCache()
            let overlay = await self.currentOverlay()
            try cache.freezeLegacyPrices(provider: provider, overlay: overlay)

            let started = Date()
            let touched = try self.scan(provider, cache: cache, overlay: overlay)
            let elapsed = Date().timeIntervalSince(started)
            if touched > 0 {
                Log.ui.info(
                    "\(provider.rawValue, privacy: .public) cost scan: \(touched) files in \(String(format: "%.1f", elapsed))s"
                )
            }

            return try CostAggregator.snapshot(provider: provider, cache: cache)
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

    /// Drops the cached price layers so the next refresh picks up an edited override file.
    public func invalidatePricing() {
        self.overlay = nil
    }

    /// Refreshes the models.dev layer if it has gone stale and folds it into the cached
    /// overlay. Returns the new overlay only when the catalog actually moved, so a caller can
    /// tell whether it has anything to redraw.
    public func refreshPricingCatalog() async -> PricingOverlay? {
        guard let catalog = await PricingOverlayStore.refreshCatalogIfStale() else { return nil }
        let overlay = PricingOverlay(
            userOverrides: PricingOverlayStore.loadUserOverrides(),
            modelsDev: catalog
        )
        self.overlay = overlay
        return overlay
    }

    /// Replaces the cached price layers outright. The app reloads them from disk instead
    /// (`invalidatePricing`); this exists so tests can move prices without touching the network.
    public func usePricingOverlay(_ overlay: PricingOverlay) {
        self.overlay = overlay
    }

    /// Called immediately before an override file changes. Every log line already on disk is
    /// scanned and priced at the rates in force right now, and rows written by older app versions
    /// are frozen the same way. A stored cost is never recomputed, so the edit that follows can
    /// only reach usage recorded after it.
    public func freezeCurrentPrices() async throws {
        let cache = try self.openCache()
        let overlay = await self.currentOverlay()
        for provider in Provider.allCases {
            try cache.freezeLegacyPrices(provider: provider, overlay: overlay)
            do {
                _ = try self.scan(provider, cache: cache, overlay: overlay)
            } catch {
                // A provider whose logs cannot be read has nothing to freeze; the other one
                // still has to be sealed before the new rates land.
                Log.ui.error(
                    "\(provider.rawValue, privacy: .public) pre-edit scan failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
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

    /// Loaded once per app run; the models.dev layer manages its own 24h disk TTL underneath.
    private func currentOverlay() async -> PricingOverlay {
        if let overlay = self.overlay { return overlay }
        let overlay = await PricingOverlayStore.load()
        self.overlay = overlay
        return overlay
    }

    /// Which scanner reads a provider's logs. The only place that mapping is spelled out.
    private func scan(_ provider: Provider, cache: CostCache, overlay: PricingOverlay) throws -> Int {
        switch provider {
        case .codex:
            let codexTouched = try CodexLogScanner.scan(cache: cache, overlay: overlay, env: self.env)
            let openCode = OpenCodeLogScanner.scan(cache: cache, overlay: overlay, env: self.env)
            self.openCodeStatus = openCode.status
            if case .error = openCode.status {
                Log.ui.error("OpenCode usage scan failed; cached usage was kept")
            }
            let pi = PiAgentLogScanner.scan(cache: cache, overlay: overlay, env: self.env)
            self.piAgentStatus = pi.status
            if case .error = pi.status {
                Log.ui.error("Pi Agent usage scan failed; cached usage was kept")
            }
            return codexTouched + openCode.touched + pi.touched
        case .claude: return try ClaudeLogScanner.scan(cache: cache, overlay: overlay, env: self.env)
        }
    }

}
