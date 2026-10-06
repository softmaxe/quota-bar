// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift
//
// Field shapes verified against real rollout files: `turn_context` announces the model for the
// turns that follow, and `event_msg` lines with `payload.type == "token_count"` carry
// `info.last_token_usage`, the delta for that turn. Summing those deltas reproduces the
// session's final `total_token_usage` exactly, which is what makes resuming mid-file safe.

import Foundation

/// Turns Codex rollout lines into observed requests. A rollout's lines are not self-contained:
/// a turn context names the model and service tier for the turns after it, and a token count is
/// only new if the running total moved. That state travels between scans as opaque saved state.
package struct CodexAdapter: AppendedLogAdapter {
    private let env: [String: String]

    package init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
    }

    package var source: AppendedLogSource { .codex }

    static func sessionRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = CodexHome.url(env: env)
        return [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    /// One copy per rollout: archiving moves or copies a live rollout into the other root.
    package func logFiles() -> [URL] {
        self.uniqueRollouts(LogFileScanner.jsonlFiles(under: Self.sessionRoots(env: self.env)))
    }

    /// Standard rollout names end in the session UUID, which survives archive moves and copies.
    /// Unrecognised names keep their path identity to avoid merging unrelated logs.
    /// Reads the path's bytes, because building a `URL` and counting characters dominated a refresh.
    /// Real rollout names are ASCII, one character per byte. Other names keep `Character`
    /// matching, where a combining mark can merge neighbouring bytes into one character.
    package func sessionID(path: String) -> String? {
        var path = path
        return path.withUTF8 { bytes in
            let file = bytes[(bytes.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0)...]
            guard file.allSatisfy({ $0 < 0x80 }) else {
                let file = Substring(String(decoding: file, as: UTF8.self))
                let name = file.hasSuffix(".jsonl") ? file.dropLast(6) : file
                guard name.hasPrefix("rollout-"), name.count >= 44 else { return nil }
                return UUID(uuidString: String(name.suffix(36)))?.uuidString
            }
            let name = file.suffix(6).elementsEqual(".jsonl".utf8) ? file.dropLast(6) : file
            guard name.count >= 44, name.starts(with: "rollout-".utf8) else { return nil }
            return UUID(uuidString: String(decoding: name.suffix(36), as: UTF8.self))?.uuidString
        }
    }

    package func isWanted(_ line: UnsafeRawBufferPointer) -> Bool {
        switch JSONLogClassifier.topLevelType(in: line) {
        case .indeterminate:
            return true
        case .turnContext:
            return true
        case .eventMessage:
            switch JSONLogClassifier.payloadType(in: line) {
            case .indeterminate, .threadSettingsApplied, .tokenCount: return true
            default: return false
            }
        default:
            return false
        }
    }

    /// New caches persist the state at the cursor. The replay fallback upgrades caches written by
    /// older app versions without forcing another full parse.
    package func parser(for file: URL, resumingAt offset: Int64, savedState: String?) -> Parser {
        let state = Self.restoredState(from: savedState)
            ?? (offset > 0 ? self.resumeState(in: file, before: offset) : ResumeState())
        return Parser(state: state)
    }

    package struct Parser: AppendedLogParser {
        private var state: ResumeState
        private let decoder = JSONDecoder()

        fileprivate init(state: ResumeState) {
            self.state = state
        }

        package var savedState: String? { try? CodexAdapter.encodedState(self.state) }

        package mutating func request(in line: UnsafeRawBufferPointer) -> ObservedRequest? {
            guard let root = self.decoder.decodeLine(Line.self, from: line) else { return nil }
            let payload = root.payload.loose()
            if CodexAdapter.applyContext(root: root, payload: payload, state: &self.state) { return nil }

            guard root.type.loose() == "event_msg",
                  payload?.type.loose() == "token_count",
                  let info = payload?.info.loose(),
                  let usage = info.last_token_usage.loose() else { return nil }

            // Codex re-emits a token_count when the rate-limit block refreshes without a new turn.
            // Those events repeat the previous last_token_usage while the running total stands
            // still, so the running total is what tells a real turn from a replay.
            let runningTotal = info.runningTotal
            defer { if let runningTotal { self.state.lastTotalUsage = runningTotal } }
            if let runningTotal, runningTotal == self.state.lastTotalUsage { return nil }

            // Codex reports input_tokens as the whole prompt, with the cached reads and the cache
            // writes both carved out of it. Peel them off in turn so each bucket is priced once.
            let rawInput = max(0, usage.input_tokens.intValue)
            let cacheRead = min(max(0, usage.cached_input_tokens.intValue), rawInput)
            let cacheWrite = min(max(0, usage.cache_write_input_tokens.intValue), rawInput - cacheRead)
            let totals = TokenTotals(
                input: rawInput - cacheRead - cacheWrite,
                // reasoning_output_tokens is a subset of output_tokens, which is what OpenAI bills.
                output: usage.output_tokens.intValue,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead
            )
            guard totals.total > 0 else { return nil }

            guard let timestamp = root.timestamp.loose(),
                  let date = ISO8601.parse(timestamp) else { return nil }

            // Older rollouts predate turn_context; their model stays nil, so their tokens count
            // but stay unpriced. Codex events have no identity, so there is no dedupe key.
            return ObservedRequest(
                key: nil,
                timestamp: date,
                model: self.state.model,
                tokens: totals,
                isFast: self.state.serviceTier.isFast
            )
        }
    }

    private func uniqueRollouts(_ files: [URL]) -> [URL] {
        // Sort on paths computed once; `URL.path` builds a new string on every call, and a
        // comparison sort would otherwise build two per comparison.
        let sorted = files.map { (url: $0, path: $0.path) }.sorted { $0.path < $1.path }
        var byID: [String: (url: URL, path: String)] = [:]
        var others: [(url: URL, path: String)] = []
        for entry in sorted {
            guard let id = self.sessionID(path: entry.path) else { others.append(entry); continue }
            if let previous = byID[id] {
                // A live copy may have more turns than the archived one.
                let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let previousSize = (try? previous.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > previousSize { byID[id] = entry }
            } else {
                byID[id] = entry
            }
        }
        return (others + byID.values).sorted { $0.path < $1.path }.map(\.url)
    }

    /// What a resumed scan has to know about the bytes it is skipping past.
    fileprivate struct ResumeState: Codable {
        /// Model announced by the most recent turn_context, as the log names it. Caches written
        /// by earlier versions hold the model's id instead, which resolves to itself.
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

    fileprivate static func encodedState(_ state: ResumeState) throws -> String {
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }

    /// The fields of a rollout line the adapter reads. Everything else is skipped unparsed.
    private struct Line: Decodable {
        let type: LooseValue<String>?
        let timestamp: LooseValue<String>?
        let payload: LooseValue<Payload>?

        struct Payload: Decodable {
            let type: LooseValue<String>?
            let model: LooseValue<String>?
            let service_tier: LooseValue<String>?
            let thread_settings: LooseValue<ThreadSettings>?
            let info: LooseValue<Info>?
        }

        struct ThreadSettings: Decodable {
            let service_tier: LooseValue<String>?
        }

        struct Info: Decodable {
            let last_token_usage: LooseValue<Usage>?
            let total_token_usage: LooseValue<[String: LooseScalar]>?

            /// The numeric fields of `total_token_usage`, which is what makes two events comparable.
            var runningTotal: [String: Int]? {
                self.total_token_usage.loose()?.compactMapValues(\.number)
            }
        }

        struct Usage: Decodable {
            let input_tokens: LooseScalar?
            let cached_input_tokens: LooseScalar?
            let cache_write_input_tokens: LooseScalar?
            let output_tokens: LooseScalar?
        }
    }

    /// Replays the bytes before `offset` to recover the state a resumed scan would otherwise
    /// have lost. Bounded by `offset`: reading past it would pick up a model announced in the
    /// appended region and attribute the turns before it to the wrong model.
    private func resumeState(in url: URL, before offset: Int64) -> ResumeState {
        var state = ResumeState()
        let decoder = JSONDecoder()
        _ = try? LogFileScanner.readLines(of: url, from: 0, upTo: offset, where: self.isWanted) { buffer in
            guard let root = decoder.decodeLine(Line.self, from: buffer),
                  let payload = root.payload.loose() else { return }

            if CodexAdapter.applyContext(root: root, payload: payload, state: &state) { return }

            guard root.type.loose() == "event_msg",
                  payload.type.loose() == "token_count",
                  let total = payload.info.loose()?.runningTotal else { return }
            state.lastTotalUsage = total
        }
        return state
    }

    /// The two lines that only move the scan's state: a turn context announcing the model and
    /// service tier, and the thread settings that can change the tier mid-file. Returns whether
    /// the line was one of them, so a fresh scan and a resumed replay read them the same way.
    private static func applyContext(
        root: Line,
        payload: Line.Payload?,
        state: inout ResumeState
    ) -> Bool {
        guard let type = root.type.loose() else { return false }
        if type == "turn_context" {
            if let tier = payload?.service_tier.loose() {
                state.serviceTier = CostPricing.CodexServiceTier.parse(tier)
            }
            if let model = payload?.model.loose()?
                .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                state.model = model
            }
            return true
        }
        if type == "event_msg", payload?.type.loose() == "thread_settings_applied" {
            let settings = payload?.thread_settings.loose()
            state.serviceTier = CostPricing.CodexServiceTier.parse(settings?.service_tier.loose())
            return true
        }
        return false
    }
}
