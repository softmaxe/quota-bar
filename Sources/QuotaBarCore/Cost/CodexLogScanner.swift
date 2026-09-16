// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift
//
// Field shapes verified against real rollout files: `turn_context` announces the model for the
// turns that follow, and `event_msg` lines with `payload.type == "token_count"` carry
// `info.last_token_usage`, the delta for that turn. Summing those deltas reproduces the
// session's final `total_token_usage` exactly, which is what makes resuming mid-file safe.

import Foundation

enum CodexLogScanner {
    static func sessionRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = CodexHome.url(env: env)
        return [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    @discardableResult
    static func scan(
        cache: CostCache,
        overlay: PricingOverlay?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        let files = Self.uniqueRollouts(LogFileScanner.jsonlFiles(under: self.sessionRoots(env: env)))
        let storedPaths = try Self.retainedPaths(cache: cache)

        var touched = 0
        for url in files {
            let sessionID = Self.sessionID(url)
            let path = sessionID.flatMap { storedPaths[$0] } ?? url.path
            let previous = cache.cursor(forPath: path)
            guard let plan = try? LogFileScanner.plan(
                for: url, previous: previous,
                matchingSessionCopy: sessionID != nil && (path != url.path || previous?.inode == 0)
            ) else { continue }
            // Deleting the live file may leave an older archive copy. It cannot roll history back.
            if sessionID != nil, let previous, plan.cursor.size < previous.size { continue }
            guard plan.requiresScan else { continue }

            // New caches persist the state at the cursor. The replay fallback upgrades caches
            // written by older app versions without forcing another full parse.
            var state = Self.restoredState(from: plan.cursor.resumeStateJSON)
                ?? (plan.cursor.offset > 0
                    ? Self.resumeState(in: url, before: plan.cursor.offset)
                    : ResumeState())

            try cache.beginTransaction()
            do {
                if plan.requiresFullReparse { try cache.forget(path: path) }
                var parseError: Error?
                let newOffset = try LogFileScanner.readLines(
                    of: url,
                    from: plan.cursor.offset,
                    upTo: plan.cursor.size
                ) { buffer in
                    guard parseError == nil else { return }
                    guard Self.isRelevant(buffer) else { return }
                    do {
                        try Self.ingest(
                            line: buffer,
                            path: path,
                            cache: cache,
                            overlay: overlay,
                            state: &state
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
                        prefixDigest: plan.cursor.prefixDigest,
                        resumeStateJSON: try Self.encodedState(state)
                    ),
                    forPath: path,
                    provider: .codex
                )
                try cache.commit()
                touched += 1
            } catch {
                cache.rollback()
                Log.codex.warning("Skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return touched
    }

    /// Standard rollout names end in the session UUID, which survives archive moves and copies.
    /// Unrecognised names keep their path identity to avoid merging unrelated logs.
    private static func sessionID(_ url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-"), name.count >= 44 else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    private static func uniqueRollouts(_ files: [URL]) -> [URL] {
        var byID: [UUID: URL] = [:]
        var others: [URL] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let id = Self.sessionID(url) else { others.append(url); continue }
            if let previous = byID[id] {
                // A live copy may have more turns than the archived one.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let previousSize = (try? previous.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > previousSize { byID[id] = url }
            } else {
                byID[id] = url
            }
        }
        return (others + byID.values).sorted { $0.path < $1.path }
    }

    private static func retainedPaths(cache: CostCache) throws -> [UUID: String] {
        var paths: [UUID: String] = [:]
        let tracked = try cache.codexTrackedPaths()
        try cache.beginTransaction()
        do {
            for path in tracked {
                guard let id = Self.sessionID(URL(fileURLWithPath: path)) else { continue }
                if paths[id] == nil {
                    paths[id] = path
                    if !FileManager.default.fileExists(atPath: path),
                       let cursor = cache.cursor(forPath: path), cursor.inode != 0 {
                        // Zero records observed deletion. A restored copy can resume, while an
                        // atomic replacement of a file that stayed present still forces a reparse.
                        try cache.setCursor(FileCursor(
                            inode: 0, size: cursor.size, offset: cursor.offset,
                            prefixDigest: cursor.prefixDigest, resumeStateJSON: cursor.resumeStateJSON
                        ), forPath: path, provider: .codex)
                    }
                } else {
                    // Older versions could count a rollout in both roots. Keep its longest scan.
                    try cache.forget(path: path)
                }
            }
            try cache.commit()
        } catch {
            cache.rollback()
            throw error
        }
        return paths
    }

    /// What a resumed scan has to know about the bytes it is skipping past.
    private struct ResumeState: Codable {
        /// Model announced by the most recent turn_context.
        var model: String?
        /// Service tier applied to subsequent turns.
        var isFast = false
        var serviceTier: CostPricing.CodexServiceTier {
            get { self.isFast ? .fast : .standard }
            set { self.isFast = newValue.isFast }
        }
        /// The most recent `total_token_usage`, which is how a re-emitted event is recognised.
        var lastTotalUsage: [String: Int]?
    }

    private static func restoredState(from json: String?) -> ResumeState? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(ResumeState.self, from: Data(json.utf8))
    }

    private static func encodedState(_ state: ResumeState) throws -> String {
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }

    private static func ingest(
        line: UnsafeRawBufferPointer,
        path: String,
        cache: CostCache,
        overlay: PricingOverlay?,
        state: inout ResumeState
    ) throws {
        let data = Data(line)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = root["payload"] as? [String: Any] ?? [:]
        if Self.applyContext(root: root, payload: payload, state: &state) { return }

        guard root["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else { return }

        // Codex re-emits a token_count when the rate-limit block refreshes without a new turn.
        // Those events repeat the previous last_token_usage while the running total stands still,
        // so the running total is what tells a real turn from a replay.
        let runningTotal = Self.totals(info["total_token_usage"])
        defer { if let runningTotal { state.lastTotalUsage = runningTotal } }
        if let runningTotal, runningTotal == state.lastTotalUsage { return }

        // Codex reports input_tokens as the whole prompt, with the cached reads and the cache
        // writes both carved out of it. Peel them off in turn so each bucket is priced once.
        let rawInput = max(0, JSONNumber.int(usage["input_tokens"]))
        let cacheRead = min(max(0, JSONNumber.int(usage["cached_input_tokens"])), rawInput)
        let cacheWrite = min(max(0, JSONNumber.int(usage["cache_write_input_tokens"])), rawInput - cacheRead)
        let totals = TokenTotals(
            input: rawInput - cacheRead - cacheWrite,
            // reasoning_output_tokens is a subset of output_tokens, which is what OpenAI bills.
            output: JSONNumber.int(usage["output_tokens"]),
            cacheWrite: cacheWrite,
            cacheRead: cacheRead
        )
        guard totals.total > 0 else { return }

        guard let timestamp = root["timestamp"] as? String,
              let date = ISO8601.parse(timestamp) else { return }

        // Older rollouts predate turn_context; count their tokens but leave them unpriced.
        let model = state.model ?? CostPricing.unknownModel
        // The long-context tier and price belong to the individual turn, not to the day's total.
        let pricing = CostPricing.pricing(
            forNormalizedModel: model,
            provider: .codex,
            overlay: overlay,
            codexServiceTier: state.serviceTier
        )
        let longContext = CostPricing.isLongContext(totals: totals, pricing: pricing)
        try cache.addCodexTokens(
            path: path,
            day: DayKey.make(from: date),
            model: model,
            longContext: longContext,
            isFast: state.serviceTier.isFast,
            totals: totals,
            costUSD: pricing?.cost(for: totals, longContext: longContext)
        )
    }

    private static func isRelevant(_ buffer: UnsafeRawBufferPointer) -> Bool {
        switch JSONLogClassifier.topLevelType(in: buffer) {
        case .indeterminate:
            return true
        case .turnContext:
            return true
        case .eventMessage:
            switch JSONLogClassifier.payloadType(in: buffer) {
            case .indeterminate, .threadSettingsApplied, .tokenCount: return true
            default: return false
            }
        default:
            return false
        }
    }

    /// Replays the bytes before `offset` to recover the state a resumed scan would otherwise
    /// have lost. Bounded by `offset`: reading past it would pick up a model announced in the
    /// appended region and attribute the turns before it to the wrong model.
    private static func resumeState(in url: URL, before offset: Int64) -> ResumeState {
        var state = ResumeState()
        _ = try? LogFileScanner.readLines(of: url, from: 0, upTo: offset) { buffer in
            guard Self.isRelevant(buffer) else { return }
            guard let root = try? JSONSerialization.jsonObject(with: Data(buffer)) as? [String: Any],
                  let payload = root["payload"] as? [String: Any] else { return }

            if Self.applyContext(root: root, payload: payload, state: &state) { return }

            guard root["type"] as? String == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = Self.totals(info["total_token_usage"]) else { return }
            state.lastTotalUsage = total
        }
        return state
    }

    /// The two lines that only move the scan's state: a turn context announcing the model and
    /// service tier, and the thread settings that can change the tier mid-file. Returns whether
    /// the line was one of them, so a fresh scan and a resumed replay read them the same way.
    private static func applyContext(
        root: [String: Any],
        payload: [String: Any],
        state: inout ResumeState
    ) -> Bool {
        guard let type = root["type"] as? String else { return false }
        if type == "turn_context" {
            if let tier = payload["service_tier"] as? String {
                state.serviceTier = CostPricing.CodexServiceTier.parse(tier)
            }
            if let model = (payload["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                // Normalize on the way in so dated aliases aggregate as one model.
                state.model = CostPricing.normalizeCodexModel(model)
            }
            return true
        }
        if type == "event_msg", payload["type"] as? String == "thread_settings_applied" {
            let settings = payload["thread_settings"] as? [String: Any]
            state.serviceTier = CostPricing.CodexServiceTier.parse(settings?["service_tier"] as? String)
            return true
        }
        return false
    }

    /// The integer fields of a `*_token_usage` object, which is what makes two events comparable.
    private static func totals(_ value: Any?) -> [String: Int]? {
        guard let usage = value as? [String: Any] else { return nil }
        return usage.compactMapValues { ($0 as? NSNumber)?.intValue }
    }
}
