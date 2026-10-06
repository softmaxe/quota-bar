import Foundation
import os

/// One request a Usage source's log reported, before any recording rule is applied.
package struct ObservedRequest: Equatable {
    /// Identity across replays, built by the adapter that understands the log format. The
    /// recorder treats it as opaque. nil for a source whose requests have no identity (Codex).
    package var key: String?
    package var timestamp: Date
    /// The model name as the log spelled it. nil when the log has not named a model yet.
    package var model: String?
    package var tokens: TokenTotals
    package var isFast: Bool

    package init(key: String?, timestamp: Date, model: String?, tokens: TokenTotals, isFast: Bool) {
        self.key = key
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.isFast = isFast
    }
}

/// Why a Usage source could not be recorded this pass. Its raw value is the reason its scan
/// status reports.
package enum ScanFailure: String {
    /// The source's sign-in could not be checked against the Codex account.
    case auth
    /// The source's session files could not be listed or read.
    case sessions
    /// A database could not be opened or written.
    case database
    /// A database another app owns did not have the shape the adapter reads.
    case schema
}

/// Proof that the caller is the Usage recorder. Only this file can create one, and opening the
/// writable `CostCache` takes one, so storage writes are unreachable outside the recorder.
struct RecordingAccess {
    fileprivate init() {}
}

/// Turns what Usage sources' logs report into Recorded usage. It owns every recording rule: the
/// local-calendar day, the Long-context tier, resuming files, transactions, and each Usage
/// source's merge rule. Long-lived and used serially by the cost module.
package final class UsageRecorder {
    /// Recorded usage storage. Only the recorder holds a connection that writes it.
    private let cache: CostCache
    /// Each snapshot source's state that Recorded usage already reflects.
    private var snapshots: [SnapshotSource: RecordedSnapshot] = [:]
    private var statuses: [CostUsageSource: ExternalAgentScanStatus] = [:]

    package init(databaseURL: URL) throws {
        self.cache = try CostCache(path: databaseURL, access: RecordingAccess())
    }

    /// Borrows the recorder's connection; read only between recordings.
    package var recordedUsageReader: RecordedUsageReader { self.cache.recordedUsageReader }

    /// Records every Usage source whose usage counts toward `provider`. A source that fails
    /// keeps what was recorded before and reports the failure in its scan status, so it never
    /// hides the others. Returns the number of files and snapshot requests that were read.
    @discardableResult
    package func record(
        _ provider: Provider,
        rateCard: RateCard,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        // `CostUsageSource.provider` alone decides which sources count toward a provider.
        var touched = 0
        for source in CostUsageSource.all where source.provider == provider {
            touched += self.record(source, rateCard: rateCard, env: env)
        }
        return touched
    }

    /// The outcome of the last pass over a Usage source.
    package func scanStatus(of source: CostUsageSource) -> ExternalAgentScanStatus {
        self.statuses[source] ?? .idle
    }

    /// Records the status a pass over `source` ended with.
    private func settle(_ source: CostUsageSource, status: ExternalAgentScanStatus) {
        self.statuses[source] = status
    }

    /// Records a failed pass over `source` and logs it, once, with what went wrong.
    private func fail(_ source: CostUsageSource, _ failure: ScanFailure, error: Error? = nil) {
        let detail = error.map { ": \($0.localizedDescription)" } ?? ""
        source.log.error(
            "\(source.displayName, privacy: .public) usage scan failed (\(failure.rawValue, privacy: .public)); recorded usage was kept\(detail, privacy: .public)"
        )
        self.statuses[source] = .error(failure.rawValue)
    }
}

// MARK: - Usage sources and their merge rules

/// The Usage sources whose logs only grow and are read from where the last scan stopped.
package enum AppendedLogSource {
    case claude
    case codex
}

/// The Usage sources read whole each pass.
package enum SnapshotSource {
    case openCode
    case piAgent
}

extension CostUsageSource {
    /// Every Usage source. Internal, so the public enum does not promise `CaseIterable`; a new
    /// source added here also needs an adapter in `UsageRecorder.record(_:rateCard:env:)`.
    static let all: [CostUsageSource] = [.codex, .openCode, .piAgent, .claude]

    fileprivate var log: Logger { self.provider == .claude ? Log.claude : Log.codex }
}

extension AppendedLogSource {
    var usageSource: CostUsageSource {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// Whether a rewritten log's rows are dropped before it is reread. Codex rows accumulate per
    /// path, so rereading without dropping them would double them. Claude Code rows are one per
    /// message and a reread re-upserts them; a message that appeared in a transcript was billed,
    /// and it may already belong to another transcript whose cursor is past it, so it is kept.
    fileprivate var dropsRowsOnRewrite: Bool {
        switch self {
        case .claude: false
        case .codex: true
        }
    }
}

extension SnapshotSource {
    var usageSource: CostUsageSource {
        switch self {
        case .openCode: .openCode
        case .piAgent: .piAgent
        }
    }
}

/// A request with every recording rule but the merge applied.
private struct RecordedRow {
    let key: String?
    let day: String
    /// The name the log reported, cleaned up; resolved to a model ID only when usage is read.
    let model: String
    let longContext: Bool
    let isFast: Bool
    let tokens: TokenTotals
}

/// How one snapshot batch's rows are flagged when first stored.
private struct SnapshotBatch {
    let included: Bool
    /// OpenCode rows stored by the first pass after the account check shipped, whose eligibility
    /// was inferred from the current sign-in rather than known when they were written.
    let legacyInferred: Bool
}

extension UsageRecorder {
    /// Which adapter reads each Usage source's logs.
    private func record(_ source: CostUsageSource, rateCard: RateCard, env: [String: String]) -> Int {
        switch source {
        case .claude: self.record(ClaudeCodeAdapter(env: env), rateCard: rateCard)
        case .codex: self.record(CodexAdapter(env: env), rateCard: rateCard)
        case .openCode: self.record(OpenCodeAdapter(env: env), rateCard: rateCard)
        case .piAgent: self.record(PiAgentAdapter(env: env), rateCard: rateCard)
        }
    }

    /// Merges a request from an appended log, read from the log at `path`.
    private func merge(_ row: RecordedRow, from source: AppendedLogSource, path: String) throws {
        switch source {
        case .claude:
            // One row per message: a replay keeps the stored row and a larger output supersedes it.
            // A rewritten transcript keeps its rows (see `dropsRowsOnRewrite`).
            try self.cache.addClaudeMessage(
                key: try Self.key(of: row, from: source.usageSource),
                path: path,
                day: row.day,
                model: row.model,
                longContext: row.longContext,
                isFast: row.isFast,
                totals: row.tokens
            )
        case .codex:
            // Codex turns have no identity, so they accumulate per path, day, model, and tier. A
            // rewritten rollout's rows are dropped before it is reparsed, so nothing doubles.
            try self.cache.addCodexTokens(
                path: path,
                day: row.day,
                model: row.model,
                longContext: row.longContext,
                isFast: row.isFast,
                totals: row.tokens
            )
        }
    }

    /// Merges a request from a snapshot, flagged as its batch says.
    private func merge(_ row: RecordedRow, from source: SnapshotSource, batch: SnapshotBatch) throws {
        switch source {
        case .openCode:
            // One row per part, rewritten only when its content changes. `included` is written
            // only when the part is first seen.
            try self.cache.addOpenCodePart(
                key: try Self.key(of: row, from: source.usageSource),
                included: batch.included,
                legacyInferred: batch.legacyInferred,
                day: row.day,
                model: row.model,
                longContext: row.longContext,
                isFast: row.isFast,
                totals: row.tokens
            )
        case .piAgent:
            // One row per message, rewritten only when its content changes. `included` is written
            // only when the message is first seen. Pi Agent records no Fast flag.
            try self.cache.addPiMessage(
                key: try Self.key(of: row, from: source.usageSource),
                included: batch.included,
                day: row.day,
                model: row.model,
                longContext: row.longContext,
                totals: row.tokens
            )
        }
    }

    /// How a snapshot batch is flagged. The first OpenCode pass after the account check shipped
    /// marks what it includes as inferred, since those rows may predate the sign-in that now
    /// decides them; Pi Agent has no such history.
    private func batch(for source: SnapshotSource, included: Bool) throws -> SnapshotBatch {
        switch source {
        case .openCode:
            SnapshotBatch(included: included, legacyInferred: try included && !self.cache.hasCompletedOpenCodeBackfill())
        case .piAgent:
            SnapshotBatch(included: included, legacyInferred: false)
        }
    }

    private static func key(of row: RecordedRow, from source: CostUsageSource) throws -> String {
        guard let key = row.key else { throw UsageRecorderError.missingKey(source) }
        return key
    }

    /// The recording rules every source shares: the local-calendar day, the cleaned-up model
    /// name, and the Long-context tier.
    private static func row(for request: ObservedRequest, provider: Provider, rateCard: RateCard) -> RecordedRow {
        // Store the name the log reported, cleaned up so `claude-opus-5` and
        // `claude-opus-5-20260101` aggregate as one model. Aliases are resolved to model IDs when
        // usage is read, so an alias a later price book adds still prices this usage.
        let model = request.model.map { ModelNames.stripped($0, provider: provider) } ?? CostPricing.unknownModel
        let day = DayKey.make(from: request.timestamp)
        // The Long-context tier is a property of the individual request, so it has to be decided
        // here, against the model ID this rate card resolves the name to; deciding it from a
        // day's aggregate would rewrite history. The price is not: it is derived from the stored
        // tokens whenever they are read.
        let longContext = rateCard.isLongContext(
            request.tokens,
            model: rateCard.modelID(recordedAs: model, provider: provider),
            provider: provider,
            day: day,
            fast: request.isFast
        )
        return RecordedRow(
            key: request.key,
            day: day,
            model: model,
            longContext: longContext,
            isFast: request.isFast,
            tokens: request.tokens
        )
    }
}

enum UsageRecorderError: LocalizedError {
    case missingKey(CostUsageSource)

    var errorDescription: String? {
        switch self {
        case let .missingKey(source): "\(source.displayName) reported a request without an identity"
        }
    }
}

// MARK: - Appended-log read mode

/// A Usage source whose logs are files that only grow, read from where the last scan stopped.
/// The adapter turns lines into observed requests and knows nothing about storage.
package protocol AppendedLogAdapter {
    associatedtype Parser: AppendedLogParser

    var source: AppendedLogSource { get }
    /// Every log file to consider this pass.
    func logFiles() -> [URL]
    /// A byte-level prefilter run before a line is parsed. It sees at most a long line's first
    /// 64KB, so it may reject a prefix only when it would reject every line starting with it.
    func isWanted(_ line: UnsafeRawBufferPointer) -> Bool
    /// A parser positioned at `offset` of `file`. `savedState` is what a parser's `savedState`
    /// returned when the cursor was last saved at that offset; it is nil when the file is read from
    /// the start or when nothing was saved.
    func parser(for file: URL, resumingAt offset: Int64, savedState: String?) -> Parser
    /// The session a log path holds, stable across moves and copies, for a source whose sessions
    /// can appear under several paths. The recorder keeps recording a session under the path it
    /// first stored it at. nil, the default, keeps the path as its own identity.
    func sessionID(path: String) -> String?
}

extension AppendedLogAdapter {
    package func sessionID(path: String) -> String? { nil }
}

/// Reads one file's lines in order, carrying whatever state the format needs across lines.
package protocol AppendedLogParser {
    /// The request a complete line reports, if any. A throw abandons the file for this pass.
    mutating func request(in line: UnsafeRawBufferPointer) throws -> ObservedRequest?
    /// Opaque state to resume from after the last parsed line, saved atomically with the cursor.
    var savedState: String? { get }
}

extension UsageRecorder {
    /// Reads what each of the adapter's files gained since the last scan. A file that fails
    /// partway leaves no rows and keeps its cursor, so a retry cannot double it, and is skipped
    /// for this pass. A failure of the whole source keeps what was recorded before and reports it
    /// in the source's scan status. Returns the number of files that contributed new bytes.
    @discardableResult
    package func record(_ adapter: some AppendedLogAdapter, rateCard: RateCard) -> Int {
        let source = adapter.source.usageSource
        do {
            let touched = try self.readNewLines(adapter, rateCard: rateCard)
            self.settle(source, status: .idle)
            return touched
        } catch {
            self.fail(source, .database, error: error)
            return 0
        }
    }

    /// A file that was rewritten rather than appended to is reread from the start, after its rows
    /// are dropped when its Usage source's merge rule requires it (see `dropsRowsOnRewrite`).
    private func readNewLines(_ adapter: some AppendedLogAdapter, rateCard: RateCard) throws -> Int {
        let source = adapter.source
        let provider = source.usageSource.provider
        let files = adapter.logFiles()
        let storedPaths = try self.retainedPaths(adapter)
        var touched = 0
        for url in files {
            let filePath = url.path
            let sessionID = adapter.sessionID(path: filePath)
            // Rows and cursor stay under the path a session was first stored at, so a moved or
            // copied log continues that session instead of counting it again.
            let path = sessionID.flatMap { storedPaths[$0] } ?? filePath
            let previous = self.cache.cursor(forPath: path)
            guard let plan = try? LogFileScanner.plan(
                for: url,
                previous: previous,
                matchingSessionCopy: sessionID != nil && (path != filePath || previous?.inode == 0)
            ) else { continue }
            // Deleting the live file may leave an older copy. It cannot roll history back.
            if sessionID != nil, let previous, plan.cursor.size < previous.size { continue }
            guard plan.requiresScan else { continue }

            try self.cache.beginTransaction()
            do {
                if plan.requiresFullReparse, source.dropsRowsOnRewrite {
                    try self.cache.forget(path: path)
                }
                var parser = adapter.parser(
                    for: url,
                    resumingAt: plan.cursor.offset,
                    savedState: plan.requiresFullReparse ? nil : plan.cursor.resumeStateJSON
                )
                var failure: Error?
                let newOffset = try LogFileScanner.readLines(
                    of: url,
                    from: plan.cursor.offset,
                    upTo: plan.cursor.size,
                    where: adapter.isWanted
                ) { line in
                    guard failure == nil else { return }
                    do {
                        guard let request = try parser.request(in: line) else { return }
                        try self.merge(
                            Self.row(for: request, provider: provider, rateCard: rateCard),
                            from: source,
                            path: path
                        )
                    } catch {
                        failure = error
                    }
                }
                if let failure { throw failure }
                try self.cache.setCursor(
                    FileCursor(
                        inode: plan.cursor.inode,
                        size: plan.cursor.size,
                        offset: newOffset,
                        prefixDigest: plan.cursor.prefixDigest,
                        resumeStateJSON: parser.savedState
                    ),
                    forPath: path,
                    provider: provider
                )
                try self.cache.commit()
                touched += 1
            } catch {
                self.cache.rollback()
                source.usageSource.log.warning(
                    "Skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return touched
    }

    /// The path each session is recorded under: the copy scanned furthest. A tracked file that
    /// has since disappeared is marked as deleted so a restored copy can resume rather than
    /// reparse, and other paths stored for the same session are dropped. Empty for a source
    /// whose paths are their own identity.
    private func retainedPaths(_ adapter: some AppendedLogAdapter) throws -> [String: String] {
        let provider = adapter.source.usageSource.provider
        var paths: [String: String] = [:]
        let tracked = try self.cache.trackedPaths(provider: provider)
        var transactionOpen = false
        do {
            for path in tracked {
                guard let id = adapter.sessionID(path: path) else { continue }
                if !transactionOpen {
                    try self.cache.beginTransaction()
                    transactionOpen = true
                }
                if paths[id] == nil {
                    paths[id] = path
                    if !FileManager.default.fileExists(atPath: path),
                       let cursor = self.cache.cursor(forPath: path), cursor.inode != 0 {
                        // Zero records observed deletion. A restored copy can resume, while an
                        // atomic replacement of a file that stayed present still forces a reparse.
                        try self.cache.setCursor(FileCursor(
                            inode: 0, size: cursor.size, offset: cursor.offset,
                            prefixDigest: cursor.prefixDigest, resumeStateJSON: cursor.resumeStateJSON
                        ), forPath: path, provider: provider)
                    }
                } else {
                    // Older versions could count a rollout in both roots. Keep its longest scan.
                    try self.cache.forget(path: path)
                }
            }
            if transactionOpen { try self.cache.commit() }
        } catch {
            if transactionOpen { self.cache.rollback() }
            throw error
        }
        return paths
    }
}

// MARK: - Whole-snapshot read mode

/// A Usage source read whole each pass, such as a database another app owns. The adapter reports
/// what the source holds and whether it counts, and knows nothing about storage.
package protocol SnapshotAdapter {
    /// Identity of the source's files at the moment they were examined. While it stays equal the
    /// source is not read again.
    associatedtype Stamp: Hashable

    var source: SnapshotSource { get }
    /// The source's current state, examined without reading its contents.
    func survey() -> SnapshotSurvey<Stamp>
    /// Every request the source holds. A `SnapshotReadError` names what failed for the scan status.
    func requests() throws -> [ObservedRequest]
}

package enum SnapshotSurvey<Stamp: Hashable> {
    /// The source is not installed, so there is nothing to record.
    case absent
    /// The source cannot be recorded this pass.
    case failed(ScanFailure)
    /// The source is present. `stamp` is nil when its files could not be examined, so it is read
    /// regardless. `included` decides whether the whole batch counts, and `status` says why not.
    case present(stamp: Stamp?, included: Bool, status: ExternalAgentScanStatus)
}

/// A snapshot source that could not be read, with what failed for its scan status.
package struct SnapshotReadError: LocalizedError {
    package let failure: ScanFailure
    package let underlying: Error?

    package init(_ failure: ScanFailure, underlying: Error? = nil) {
        self.failure = failure
        self.underlying = underlying
    }

    package var errorDescription: String? {
        self.underlying.map { "\(self.failure.rawValue): \($0.localizedDescription)" } ?? self.failure.rawValue
    }
}

/// A snapshot Recorded usage reflects. The time zone decides each row's day and `included` each
/// row's flag, so a change to either rereads the source even when its files did not change.
private struct RecordedSnapshot: Equatable {
    let stamp: AnyHashable
    let timeZone: String
    let included: Bool
}

extension UsageRecorder {
    /// Records a source read whole: skipped while its snapshot is unchanged, otherwise every
    /// request is stored in one transaction under one `included` value. A source that fails keeps
    /// what was recorded before and reports the failure in its scan status. Returns the number of
    /// requests read.
    @discardableResult
    package func record<Adapter: SnapshotAdapter>(_ adapter: Adapter, rateCard: RateCard) -> Int {
        let source = adapter.source
        switch adapter.survey() {
        case .absent:
            self.snapshots[source] = nil
            self.settle(source.usageSource, status: .idle)
            return 0
        case let .failed(failure):
            self.snapshots[source] = nil
            self.fail(source.usageSource, failure)
            return 0
        case let .present(stamp, included, status):
            let snapshot = stamp.map {
                RecordedSnapshot(stamp: AnyHashable($0), timeZone: TimeZone.current.identifier, included: included)
            }
            if let snapshot, snapshot == self.snapshots[source] {
                self.settle(source.usageSource, status: status)
                return 0
            }
            do {
                let requests = try adapter.requests()
                try self.storeSnapshot(requests, from: source, included: included, rateCard: rateCard)
                self.snapshots[source] = snapshot
                self.settle(source.usageSource, status: status)
                return requests.count
            } catch {
                self.snapshots[source] = nil
                self.fail(
                    source.usageSource,
                    (error as? SnapshotReadError)?.failure ?? .database,
                    error: error
                )
                return 0
            }
        }
    }

    private func storeSnapshot(
        _ requests: [ObservedRequest],
        from source: SnapshotSource,
        included: Bool,
        rateCard: RateCard
    ) throws {
        let provider = source.usageSource.provider
        let batch = try self.batch(for: source, included: included)
        try self.cache.beginTransaction()
        do {
            for request in requests {
                try self.merge(Self.row(for: request, provider: provider, rateCard: rateCard), from: source, batch: batch)
            }
            if batch.legacyInferred { try self.cache.markOpenCodeBackfillComplete() }
            try self.cache.commit()
        } catch {
            self.cache.rollback()
            throw error
        }
    }
}
