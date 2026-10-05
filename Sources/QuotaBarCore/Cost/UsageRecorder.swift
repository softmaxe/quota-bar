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
    let cache: CostCache

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
        switch provider {
        case .claude:
            return try self.record(ClaudeCodeAdapter(env: env), rateCard: rateCard)
        case .codex:
            // OpenCode and Pi Agent are still recorded by their own scanners.
            return try self.record(CodexAdapter(env: env), rateCard: rateCard)
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
    private func store(
        _ request: ObservedRequest,
        from source: CostUsageSource,
        path: String,
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
            try self.cache.addCodexTokens(
                path: path,
                day: day,
                model: model,
                longContext: longContext,
                isFast: request.isFast,
                totals: request.tokens
            )
        case .openCode, .piAgent:
            throw UsageRecorderError.unsupportedSource(source)
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
