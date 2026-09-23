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
    private let book: PriceBook
    private var openCodeStatus: OpenCodeScanStatus = .idle
    private var piAgentStatus: PiAgentScanStatus = .idle
    /// The Pi Agent session files the store already reflects, so an unchanged directory is not
    /// re-read on every Codex refresh.
    private var piAgentSessions: PiAgentLogScanner.SessionSnapshot?
    /// Readable without the actor so `CostUsageReader` can open the same file on a connection
    /// of its own rather than queueing behind a scan.
    public nonisolated let databaseURL: URL
    private let env: [String: String]

    /// `pricingOverlay` pins the user overrides instead of reading the file, and `priceBook`
    /// replaces the bundled rates; tests use both to keep prices fixed.
    public init(
        databaseURL: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        pricingOverlay: PricingOverlay? = nil,
        priceBook: PriceBook = .bundled
    ) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
        self.env = env
        self.overlay = pricingOverlay
        self.book = priceBook
    }

    /// `~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite`.
    public static var defaultDatabaseURL: URL {
        CostDatabaseLocation.defaultURL
    }

    public func refresh(_ provider: Provider) async -> CostSnapshot? {
        do {
            let cache = try self.openCache()
            let overlay = self.currentOverlay()

            let started = Date()
            let touched = try self.scan(provider, cache: cache, overlay: overlay)
            let elapsed = Date().timeIntervalSince(started)
            if touched > 0 {
                Log.ui.info(
                    "\(provider.rawValue, privacy: .public) cost scan: \(touched) files in \(String(format: "%.1f", elapsed))s"
                )
            }

            return try CostAggregator.snapshot(
                provider: provider,
                cache: cache,
                overlay: overlay,
                book: self.book
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

    /// Drops the cached overrides so the next refresh picks up an edited override file. Cost is
    /// derived when it is read, so that refresh reprices all recorded usage at the new rates.
    public func invalidatePricing() {
        self.overlay = nil
    }

    /// Replaces the cached overrides outright. The app reloads them from disk instead
    /// (`invalidatePricing`); this exists so tests can move prices without touching the file.
    public func usePricingOverlay(_ overlay: PricingOverlay) {
        self.overlay = overlay
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
    private func currentOverlay() -> PricingOverlay {
        if let overlay = self.overlay { return overlay }
        let overlay = PricingOverlayStore.loadFromDisk()
        self.overlay = overlay
        return overlay
    }

    /// Which scanner reads a provider's logs. The only place that mapping is spelled out.
    private func scan(_ provider: Provider, cache: CostCache, overlay: PricingOverlay) throws -> Int {
        switch provider {
        case .codex:
            let codexTouched = try CodexLogScanner.scan(
                cache: cache,
                overlay: overlay,
                book: self.book,
                env: self.env
            )
            let openCode = OpenCodeLogScanner.scan(cache: cache, overlay: overlay, book: self.book, env: self.env)
            self.openCodeStatus = openCode.status
            if case .error = openCode.status {
                Log.ui.error("OpenCode usage scan failed; cached usage was kept")
            }
            let pi = PiAgentLogScanner.scan(
                cache: cache,
                overlay: overlay,
                book: self.book,
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
            return try ClaudeLogScanner.scan(cache: cache, overlay: overlay, book: self.book, env: self.env)
        }
    }

}
