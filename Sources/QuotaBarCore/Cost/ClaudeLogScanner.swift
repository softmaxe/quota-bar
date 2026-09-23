// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift
//
// Field shapes verified against real transcripts: assistant lines carry `message.model`,
// `message.id`, `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,
// cache_read_input_tokens}` and `usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`,
// plus a top-level `requestId` and `timestamp`.

import Foundation

enum ClaudeLogScanner {
    static func projectRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let configDir = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDir.isEmpty {
            return [URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
                .appendingPathComponent("projects", isDirectory: true)]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
    }

    /// Parses new bytes of every transcript into the cache. Returns the number of files touched.
    @discardableResult
    static func scan(
        cache: CostCache,
        overlay: PricingOverlay?,
        book: PriceBook = .bundled,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        let files = LogFileScanner.jsonlFiles(under: self.projectRoots(env: env))
        let decoder = JSONDecoder()

        var touched = 0
        for url in files {
            let previous = cache.cursor(forPath: url.path)
            guard let plan = try? LogFileScanner.plan(for: url, previous: previous) else { continue }
            guard plan.requiresScan else { continue }

            try cache.beginTransaction()
            do {
                if plan.requiresFullReparse { try cache.forget(path: url.path) }
                var parseError: Error?
                let newOffset = try LogFileScanner.readLines(
                    of: url,
                    from: plan.cursor.offset,
                    upTo: plan.cursor.size
                ) { buffer in
                    guard parseError == nil else { return }
                    let type = JSONLogClassifier.topLevelType(in: buffer)
                    guard type == .assistant || type == .indeterminate else { return }
                    do {
                        try Self.ingest(
                            line: buffer,
                            path: url.path,
                            cache: cache,
                            overlay: overlay,
                            book: book,
                            decoder: decoder
                        )
                    } catch {
                        parseError = error
                    }
                }
                if let parseError { throw parseError }
                try cache.setCursor(
                    FileCursor(
                        inode: plan.cursor.inode,
                        size: plan.cursor.size,
                        offset: newOffset,
                        prefixDigest: plan.cursor.prefixDigest
                    ),
                    forPath: url.path,
                    provider: .claude
                )
                try cache.commit()
                touched += 1
            } catch {
                cache.rollback()
                Log.claude.warning("Skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return touched
    }

    /// The fields of a transcript line the scanner reads. Everything else is skipped unparsed.
    private struct Line: Decodable {
        let type: LooseValue<String>?
        let timestamp: LooseValue<String>?
        let requestId: LooseValue<String>?
        let uuid: LooseValue<String>?
        let message: LooseValue<Message>?

        struct Message: Decodable {
            let id: LooseValue<String>?
            let model: LooseValue<String>?
            let usage: LooseValue<Usage>?
        }

        struct Usage: Decodable {
            let input_tokens: LooseScalar?
            let output_tokens: LooseScalar?
            let cache_creation_input_tokens: LooseScalar?
            let cache_read_input_tokens: LooseScalar?
            let cache_creation: LooseValue<CacheCreation>?
        }

        struct CacheCreation: Decodable {
            let ephemeral_1h_input_tokens: LooseScalar?
        }
    }

    private static func ingest(
        line: UnsafeRawBufferPointer,
        path: String,
        cache: CostCache,
        overlay: PricingOverlay?,
        book: PriceBook,
        decoder: JSONDecoder
    ) throws {
        guard let root = decoder.decodeLine(Line.self, from: line),
              root.type.loose() == "assistant",
              let message = root.message.loose(),
              let usage = message.usage.loose() else { return }

        let rawModel = message.model.loose()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawModel.isEmpty, rawModel != "<synthetic>" else { return }
        // Normalize before storing so `claude-opus-5` and `claude-opus-5-20260101` aggregate as
        // one model rather than competing for the top-model slot.
        let model = CostPricing.normalizeClaudeModel(rawModel)

        // Anthropic reports input_tokens already net of both cache buckets, so unlike Codex
        // nothing has to be peeled out of it here.
        let cacheWrite = usage.cache_creation_input_tokens.intValue
        let cacheCreation = usage.cache_creation.loose()
        let totals = TokenTotals(
            input: usage.input_tokens.intValue,
            output: usage.output_tokens.intValue,
            cacheWrite: cacheWrite,
            // The two TTLs are billed differently, and the 1h bucket dominates on long sessions.
            cacheWrite1h: min(cacheCreation?.ephemeral_1h_input_tokens.intValue ?? 0, cacheWrite),
            cacheRead: usage.cache_read_input_tokens.intValue
        )
        guard totals.total > 0 else { return }

        guard let timestamp = root.timestamp.loose(),
              let date = ISO8601.parse(timestamp) else { return }

        // The same assistant message is replayed into resumed and forked transcripts, so identity
        // comes from the message id paired with the request that produced it.
        let messageId = message.id.loose() ?? ""
        let requestId = root.requestId.loose() ?? ""
        let key: String
        if messageId.isEmpty, requestId.isEmpty {
            // Nothing stable to dedupe on; fall back to the line's own uuid.
            key = "uuid:\(root.uuid.loose() ?? UUID().uuidString)"
        } else {
            key = "\(messageId)|\(requestId)"
        }

        // The long-context tier is a property of the individual request, so it has to be decided
        // here; deciding it from a day's aggregate would rewrite history. The price is not: it is
        // derived from the stored tokens whenever they are read.
        let day = DayKey.make(from: date)
        let pricing = CostPricing.pricing(
            forNormalizedModel: model,
            provider: .claude,
            day: day,
            overlay: overlay,
            book: book
        )
        try cache.addClaudeMessage(
            key: key,
            path: path,
            day: day,
            model: model,
            longContext: CostPricing.isLongContext(totals: totals, pricing: pricing),
            totals: totals
        )
    }
}
