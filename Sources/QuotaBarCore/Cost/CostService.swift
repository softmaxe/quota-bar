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
    private var recorder: UsageRecorder?
    /// The rates of the current refresh. nil until the third-party rates are next read.
    private var rateCard: RateCard?
    /// What a dropped rate card is rebuilt from.
    private var book: PriceBook
    /// nil prices third-party models from nothing and never downloads, which is what tests and
    /// previews want.
    private let modelsDev: ModelsDevPricing?
    /// When models.dev was last read successfully, once the cache has been looked at.
    private var lastFetch: Date??
    /// The last download attempted, so a failing one is not retried on every refresh.
    private var lastFetchAttempt: Date?
    /// Readable without the actor so `CostUsageReader` can open the same file on a connection
    /// of its own rather than queueing behind a scan.
    public nonisolated let databaseURL: URL
    /// Where `RemoteLogMirror` keeps other machines' logs, beside the database they feed.
    public nonisolated var remoteLogsURL: URL {
        self.databaseURL.deletingLastPathComponent().appendingPathComponent("remote-logs", isDirectory: true)
    }
    private let env: [String: String]

    /// models.dev is read at most once a day, and a failed download waits an hour.
    static let fetchInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60

    /// `rateCard` pins the rates until `invalidatePricing`; tests use it to keep prices fixed. Its
    /// book, the shipped one when none is pinned, is what the third-party rates sit beside after
    /// that.
    public init(
        databaseURL: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        rateCard: RateCard? = nil,
        modelsDev: ModelsDevPricing? = nil
    ) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
        self.env = env
        self.rateCard = rateCard
        self.book = rateCard?.book ?? .bundled
        self.modelsDev = modelsDev
    }

    /// `~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite`.
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar/cost-usage", isDirectory: true)
            .appendingPathComponent("cost-usage.sqlite", isDirectory: false)
    }

    public func refresh(_ provider: Provider) async -> CostSnapshot? {
        do {
            let recorder = try self.openRecorder()
            // One rate card for the whole refresh, so the scan and the pricing never disagree.
            let rateCard = self.currentRateCard()

            let started = Date()
            let touched = recorder.record(
                provider,
                rateCard: rateCard,
                env: self.env,
                remoteLogs: self.remoteLogsURL
            )
            let elapsed = Date().timeIntervalSince(started)
            if touched > 0 {
                Log.ui.info(
                    "\(provider.rawValue, privacy: .public) cost scan: \(touched) files in \(String(format: "%.1f", elapsed))s"
                )
            }

            return try CostAggregator.snapshot(
                provider: provider,
                reader: recorder.recordedUsageReader,
                rateCard: rateCard
            )
        } catch {
            Log.ui.error(
                "\(provider.rawValue, privacy: .public) cost scan failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The outcome of the last scan of a Usage source.
    public func currentScanStatus(of source: CostUsageSource) -> ExternalAgentScanStatus {
        self.recorder?.scanStatus(of: source) ?? .idle
    }

    /// Every Usage source's last scan outcome, in display order.
    public func currentScanStatuses() -> [(source: CostUsageSource, status: ExternalAgentScanStatus)] {
        CostUsageSource.all
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { (source: $0, status: self.currentScanStatus(of: $0)) }
    }

    /// Drops the rate card so the next refresh reads the third-party rates again. Cost is derived
    /// when it is read, so that refresh reprices all recorded usage at the new rates.
    public func invalidatePricing() {
        self.rateCard = nil
    }

    /// Downloads models.dev when the last successful read is a day old, and folds it into the
    /// local cache. Returns true when the rates changed, so the caller can reprice. Does nothing
    /// while the setting is off.
    public func updateThirdPartyRates(now: Date = Date()) async -> Bool {
        guard let modelsDev = self.modelsDev, modelsDev.enabled else { return false }
        if self.lastFetch == nil { self.lastFetch = .some(modelsDev.cached().fetchedAt) }
        if let fetched = self.lastFetch ?? nil, now.timeIntervalSince(fetched) < Self.fetchInterval { return false }
        if let attempt = self.lastFetchAttempt, now.timeIntervalSince(attempt) < Self.retryInterval { return false }
        // Claimed before the download, so a refresh arriving meanwhile does not start another.
        self.lastFetchAttempt = now
        do {
            let rates = try await modelsDev.fetch(into: modelsDev.cached(), now: now)
            self.lastFetch = .some(rates.fetchedAt)
            self.rateCard = nil
            Log.ui.info("models.dev rates updated: \(rates.models.count) models")
            return true
        } catch {
            Log.ui.error("models.dev rates were not updated: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Replaces the rate card outright. The app rereads the third-party rates instead
    /// (`invalidatePricing`); this exists so tests can move prices without touching the cache.
    public func useRateCard(_ rateCard: RateCard) {
        self.rateCard = rateCard
        self.book = rateCard.book
    }

    /// Writes a backup of Recorded usage to `destination`, replacing any file there only once the
    /// backup is complete. Waits for a scan in progress.
    public func exportBackup(to destination: URL) throws {
        let recorder = try self.openRecorder()
        try UsageBackup.publish(to: destination, write: recorder.writeSnapshot(to:))
    }

    /// Adds what the backup at `source` holds and this database lacks, and removes nothing. The
    /// database as it stood stays beside it in `undoCopyURL`. Waits for a scan in progress.
    public func importBackup(from source: URL) throws -> UsageImportResult {
        let recorder = try self.openRecorder()
        return try UsageBackup.withStagedCopy(of: source) {
            try recorder.merge(backup: $0, undoCopy: self.undoCopyURL)
        }
    }

    /// The database as it stood before the latest import.
    public nonisolated var undoCopyURL: URL {
        self.databaseURL.deletingLastPathComponent()
            .appendingPathComponent(self.databaseURL.lastPathComponent + ".pre-import", isDirectory: false)
    }

    private func openRecorder() throws -> UsageRecorder {
        if let recorder = self.recorder { return recorder }
        let recorder = try UsageRecorder(databaseURL: self.databaseURL)
        self.recorder = recorder
        return recorder
    }

    /// Read from disk once, then again only after `invalidatePricing`.
    private func currentRateCard() -> RateCard {
        if let rateCard = self.rateCard { return rateCard }
        let rateCard = RateCard(book: self.book, thirdParty: self.modelsDev?.rates() ?? .empty)
        self.rateCard = rateCard
        return rateCard
    }
}
