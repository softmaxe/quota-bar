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

/// A Usage source whose logs are files that only grow, read from where the last scan stopped.
/// The adapter turns lines into observed requests and knows nothing about storage.
package protocol AppendedLogAdapter {
    associatedtype Parser: AppendedLogParser

    var source: CostUsageSource { get }
    /// Every log file to consider this pass.
    func logFiles() -> [URL]
    /// A byte-level prefilter run before a line is parsed. It sees at most a long line's first
    /// 64KB, so it may reject a prefix only when it would reject every line starting with it.
    func isWanted(_ line: UnsafeRawBufferPointer) -> Bool
    /// A parser positioned at `offset` of `file`. `savedState` is what a parser's `savedState`
    /// returned when the cursor was last saved at that offset; it is nil when the file is read from
    /// the start or when nothing was saved.
    func parser(for file: URL, resumingAt offset: Int64, savedState: String?) throws -> Parser
    /// Whether one session's log can appear under several paths (moved or copied between roots).
    /// When it can, the recorder keeps recording a session under the path it first stored it at.
    var identifiesSessions: Bool { get }
    /// The session a log path holds, stable across moves and copies. nil keeps the path as its
    /// own identity. Only asked when `identifiesSessions` is true.
    func sessionID(path: String) -> String?
}

extension AppendedLogAdapter {
    package var identifiesSessions: Bool { false }
    package func sessionID(path: String) -> String? { nil }
}

/// Reads one file's lines in order, carrying whatever state the format needs across lines.
package protocol AppendedLogParser {
    /// The request a complete line reports, if any. A throw abandons the file for this pass.
    mutating func request(in line: UnsafeRawBufferPointer) throws -> ObservedRequest?
    /// Opaque state to resume from after the last parsed line, saved atomically with the cursor.
    var savedState: String? { get }
}

/// Turns what Usage sources' logs report into Recorded usage. It owns every recording rule: the
/// local-calendar day, model ID resolution, the Long-context tier, resuming files, transactions,
/// and each Usage source's merge rule. Long-lived and used serially by the cost module.
package final class UsageRecorder {
    /// Recorded usage storage. Only the recorder holds a connection that writes it.
    private let cache: CostCache
    /// Each snapshot source's state that Recorded usage already reflects.
    private var snapshots: [CostUsageSource: RecordedSnapshot] = [:]
    private var statuses: [CostUsageSource: ExternalAgentScanStatus] = [:]

    package init(databaseURL: URL) throws {
        self.cache = try CostCache(path: databaseURL)
    }

    /// Borrows the recorder's connection; read only between recordings.
    package var recordedUsageReader: RecordedUsageReader { self.cache.recordedUsageReader }

    /// Records every Usage source whose usage counts toward `provider`. Returns the number of
    /// files that contributed new bytes.
    @discardableResult
    package func record(
        _ provider: Provider,
        rateCard: RateCard,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        // `CostUsageSource.provider` alone decides which sources count toward a provider. Cases
        // are visited in declaration order, so Codex is recorded before OpenCode and Pi Agent,
        // and a Codex failure ends the refresh before they are read.
        var touched = 0
        for source in CostUsageSource.allCases where source.provider == provider {
            touched += try self.record(source, rateCard: rateCard, env: env)
        }
        return touched
    }

    /// Which adapter reads a Usage source's logs.
    private func record(_ source: CostUsageSource, rateCard: RateCard, env: [String: String]) throws -> Int {
        switch source {
        case .claude: try self.record(ClaudeCodeAdapter(env: env), rateCard: rateCard)
        case .codex: try self.record(CodexAdapter(env: env), rateCard: rateCard)
        case .openCode: self.record(OpenCodeAdapter(env: env), rateCard: rateCard)
        case .piAgent: self.record(PiAgentAdapter(env: env), rateCard: rateCard)
        }
    }

    /// Reads what each of the adapter's files gained since the last scan. A file that was
    /// rewritten rather than appended to is reread from the start, after its rows are dropped
    /// when its Usage source's merge rule requires it (see `dropsRowsOnRewrite`). A
    /// file that fails partway leaves no rows and keeps its cursor, so a retry cannot double it.
    @discardableResult
    package func record(_ adapter: some AppendedLogAdapter, rateCard: RateCard) throws -> Int {
        let provider = adapter.source.provider
        let files = adapter.logFiles()
        let storedPaths = adapter.identifiesSessions ? try self.retainedPaths(adapter) : [:]
        var touched = 0
        for url in files {
            let filePath = url.path
            let sessionID = adapter.identifiesSessions ? adapter.sessionID(path: filePath) : nil
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
                if plan.requiresFullReparse, Self.dropsRowsOnRewrite(adapter.source) {
                    try self.cache.forget(path: path)
                }
                var parser = try adapter.parser(
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
                        try self.store(request, from: adapter.source, path: path, rateCard: rateCard)
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
                Self.log(provider).warning(
                    "Skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return touched
    }

    /// Applies the recording rules to one request and merges it under its Usage source's rule.
    /// `path` is the appended log a request came from; `batch` flags a snapshot source's rows.
    private func store(
        _ request: ObservedRequest,
        from source: CostUsageSource,
        path: String? = nil,
        batch: SnapshotBatch? = nil,
        rateCard: RateCard
    ) throws {
        let provider = source.provider
        // Normalize before storing so `claude-opus-5` and `claude-opus-5-20260101` aggregate as
        // one model rather than competing for the top-model slot.
        let model = request.model.map { rateCard.modelID(for: $0, provider: provider) } ?? CostPricing.unknownModel
        let day = DayKey.make(from: request.timestamp)
        // The Long-context tier is a property of the individual request, so it has to be decided
        // here; deciding it from a day's aggregate would rewrite history. The price is not: it is
        // derived from the stored tokens whenever they are read.
        let longContext = rateCard.isLongContext(
            request.tokens,
            model: model,
            provider: provider,
            day: day,
            fast: request.isFast
        )
        switch source {
        case .claude:
            // One row per message: a replay keeps the stored row and a larger output supersedes it.
            guard let key = request.key else { throw UsageRecorderError.missingKey(source) }
            guard let path else { throw UsageRecorderError.unsupportedSource(source) }
            try self.cache.addClaudeMessage(
                key: key,
                path: path,
                day: day,
                model: model,
                longContext: longContext,
                isFast: request.isFast,
                totals: request.tokens
            )
        case .codex:
            // Codex turns have no identity, so they accumulate per path, day, model, and tier. A
            // rewritten rollout's rows are dropped before it is reparsed, so nothing doubles.
            guard let path else { throw UsageRecorderError.unsupportedSource(source) }
            try self.cache.addCodexTokens(
                path: path,
                day: day,
                model: model,
                longContext: longContext,
                isFast: request.isFast,
                totals: request.tokens
            )
        case .openCode:
            // One row per part, rewritten only when its content changes. `included` is written
            // only when the part is first seen.
            guard let key = request.key else { throw UsageRecorderError.missingKey(source) }
            guard let batch else { throw UsageRecorderError.unsupportedSource(source) }
            try self.cache.addOpenCodePart(
                key: key,
                included: batch.included,
                legacyInferred: batch.legacyInferred,
                day: day,
                model: model,
                longContext: longContext,
                isFast: request.isFast,
                totals: request.tokens
            )
        case .piAgent:
            // One row per message, rewritten only when its content changes. `included` is written
            // only when the message is first seen. Pi Agent records no Fast flag.
            guard let key = request.key else { throw UsageRecorderError.missingKey(source) }
            guard let batch else { throw UsageRecorderError.unsupportedSource(source) }
            try self.cache.addPiMessage(
                key: key,
                included: batch.included,
                day: day,
                model: model,
                longContext: longContext,
                totals: request.tokens
            )
        }
    }

    /// The path each session is recorded under: the copy scanned furthest. A tracked file that
    /// has since disappeared is marked as deleted so a restored copy can resume rather than
    /// reparse, and other paths stored for the same session are dropped.
    private func retainedPaths(_ adapter: some AppendedLogAdapter) throws -> [String: String] {
        let provider = adapter.source.provider
        var paths: [String: String] = [:]
        let tracked = try self.cache.trackedPaths(provider: provider)
        try self.cache.beginTransaction()
        do {
            for path in tracked {
                guard let id = adapter.sessionID(path: path) else { continue }
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
            try self.cache.commit()
        } catch {
            self.cache.rollback()
            throw error
        }
        return paths
    }

    /// Whether a rewritten log's rows are dropped before it is reread. Codex rows accumulate per
    /// path, so rereading without dropping them would double them. Claude Code rows are one per
    /// message and a reread re-upserts them; a message that appeared in a transcript was billed,
    /// and it may already belong to another transcript whose cursor is past it, so it is kept.
    private static func dropsRowsOnRewrite(_ source: CostUsageSource) -> Bool {
        source != .claude
    }

    private static func log(_ provider: Provider) -> Logger {
        provider == .claude ? Log.claude : Log.codex
    }
}

enum UsageRecorderError: LocalizedError {
    case unsupportedSource(CostUsageSource)
    case missingKey(CostUsageSource)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSource(source): "\(source.displayName) usage is not recorded from appended logs"
        case let .missingKey(source): "\(source.displayName) reported a request without an identity"
        }
    }
}

// MARK: - Whole-snapshot read mode

/// A Usage source read whole each pass, such as a database another app owns. The adapter reports
/// what the source holds and whether it counts, and knows nothing about storage.
package protocol SnapshotAdapter {
    /// Identity of the source's files at the moment they were examined. While it stays equal the
    /// source is not read again.
    associatedtype Stamp: Hashable

    var source: CostUsageSource { get }
    /// The source's current state, examined without reading its contents.
    func survey() -> SnapshotSurvey<Stamp>
    /// Every request the source holds. A `SnapshotReadError` names what failed for the scan status.
    func requests() throws -> [ObservedRequest]
}

package enum SnapshotSurvey<Stamp: Hashable> {
    /// The source is not installed, so there is nothing to record.
    case absent
    /// The source cannot be recorded this pass, for the named reason.
    case failed(reason: String)
    /// The source is present. `stamp` is nil when its files could not be examined, so it is read
    /// regardless. `included` decides whether the whole batch counts, and `status` says why not.
    case present(stamp: Stamp?, included: Bool, status: ExternalAgentScanStatus)
}

/// A snapshot source that could not be read, with the reason its scan status reports.
package struct SnapshotReadError: Error {
    package let reason: String

    package init(_ reason: String) {
        self.reason = reason
    }
}

/// How one snapshot batch's rows are flagged when first stored.
private struct SnapshotBatch {
    let included: Bool
    /// OpenCode rows stored by the first pass after the account check shipped, whose eligibility
    /// was inferred from the current sign-in rather than known when they were written.
    let legacyInferred: Bool
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
            self.settle(source, status: .idle, snapshot: nil)
            return 0
        case let .failed(reason):
            self.settle(source, status: .error(reason), snapshot: nil)
            return 0
        case let .present(stamp, included, status):
            let snapshot = stamp.map {
                RecordedSnapshot(stamp: AnyHashable($0), timeZone: TimeZone.current.identifier, included: included)
            }
            if let snapshot, snapshot == self.snapshots[source] {
                self.settle(source, status: status, snapshot: snapshot)
                return 0
            }
            do {
                let requests = try adapter.requests()
                try self.storeSnapshot(requests, from: source, included: included, rateCard: rateCard)
                self.settle(source, status: status, snapshot: snapshot)
                return requests.count
            } catch {
                self.settle(source, status: .error((error as? SnapshotReadError)?.reason ?? "database"), snapshot: nil)
                return 0
            }
        }
    }

    /// The outcome of the last pass over a snapshot source.
    package func scanStatus(of source: CostUsageSource) -> ExternalAgentScanStatus {
        self.statuses[source] ?? .idle
    }

    private func storeSnapshot(
        _ requests: [ObservedRequest],
        from source: CostUsageSource,
        included: Bool,
        rateCard: RateCard
    ) throws {
        // The first OpenCode pass after the account check shipped marks what it includes as
        // inferred, since those rows may predate the sign-in that now decides them.
        let legacy = try source == .openCode && included && !self.cache.hasCompletedOpenCodeBackfill()
        let batch = SnapshotBatch(included: included, legacyInferred: legacy)
        try self.cache.beginTransaction()
        do {
            for request in requests {
                try self.store(request, from: source, batch: batch, rateCard: rateCard)
            }
            if legacy { try self.cache.markOpenCodeBackfillComplete() }
            try self.cache.commit()
        } catch {
            self.cache.rollback()
            throw error
        }
    }

    private func settle(_ source: CostUsageSource, status: ExternalAgentScanStatus, snapshot: RecordedSnapshot?) {
        self.statuses[source] = status
        self.snapshots[source] = snapshot
        if case .error = status {
            Log.ui.error("\(source.displayName, privacy: .public) usage scan failed; cached usage was kept")
        }
    }
}
