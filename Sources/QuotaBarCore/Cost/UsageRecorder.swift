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
            // Codex, OpenCode, and Pi Agent are still recorded by their own scanners.
            return 0
        }
    }

    /// Reads what each of the adapter's files gained since the last scan. A file that was
    /// rewritten rather than appended to is reread from the start after its rows are dropped. A
    /// file that fails partway leaves no rows and keeps its cursor, so a retry cannot double it.
    @discardableResult
    package func record(_ adapter: some AppendedLogAdapter, rateCard: RateCard) throws -> Int {
        let provider = adapter.source.provider
        var touched = 0
        for url in adapter.logFiles() {
            let previous = self.cache.cursor(forPath: url.path)
            guard let plan = try? LogFileScanner.plan(for: url, previous: previous) else { continue }
            guard plan.requiresScan else { continue }

            try self.cache.beginTransaction()
            do {
                if plan.requiresFullReparse { try self.cache.forget(path: url.path) }
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
                        try self.store(request, from: adapter.source, path: url.path, rateCard: rateCard)
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
                    forPath: url.path,
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
        case .codex, .openCode, .piAgent:
            throw UsageRecorderError.unsupportedSource(source)
        }
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
