// Adapted from CodexBar (MIT, © 2026 Peter Steinberger):
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift
//
// Field shapes verified against real transcripts: assistant lines carry `message.model`,
// `message.id`, `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,
// cache_read_input_tokens,speed}` and `usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`,
// plus a top-level `requestId` and `timestamp`. `speed` is `"standard"` or `"fast"`.

import Foundation

/// Turns Claude Code transcript lines into observed requests.
package struct ClaudeCodeAdapter: AppendedLogAdapter {
    private let env: [String: String]

    package init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
    }

    package var source: AppendedLogSource { .claude }

    static func projectRoots(env: [String: String]) -> [URL] {
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

    package func logFiles() -> [URL] {
        LogFileScanner.jsonlFiles(under: Self.projectRoots(env: self.env))
    }

    package func isWanted(_ line: UnsafeRawBufferPointer) -> Bool {
        let type = JSONLogClassifier.topLevelType(in: line)
        return type == .assistant || type == .indeterminate
    }

    /// Transcript lines stand alone, so there is nothing to carry across them or resume from.
    package func parser(for file: URL, resumingAt offset: Int64, savedState: String?) -> Parser {
        Parser()
    }

    package struct Parser: AppendedLogParser {
        private let decoder = JSONDecoder()

        package init() {}

        package var savedState: String? { nil }

        package func request(in line: UnsafeRawBufferPointer) -> ObservedRequest? {
            guard let root = self.decoder.decodeLine(Line.self, from: line),
                  root.type.loose() == "assistant",
                  let message = root.message.loose(),
                  let usage = message.usage.loose() else { return nil }

            let model = message.model.loose()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Claude Code writes `<synthetic>` for messages it made up locally; nothing was billed.
            guard !model.isEmpty, model != "<synthetic>" else { return nil }

            // Anthropic reports input_tokens already net of both cache buckets, so unlike Codex
            // nothing has to be peeled out of it here.
            let cacheWrite = usage.cache_creation_input_tokens.intValue
            let cacheCreation = usage.cache_creation.loose()
            let tokens = TokenTotals(
                input: usage.input_tokens.intValue,
                output: usage.output_tokens.intValue,
                cacheWrite: cacheWrite,
                // The two TTLs are billed differently, and the 1h bucket dominates on long sessions.
                cacheWrite1h: min(cacheCreation?.ephemeral_1h_input_tokens.intValue ?? 0, cacheWrite),
                cacheRead: usage.cache_read_input_tokens.intValue
            )
            guard tokens.total > 0 else { return nil }

            guard let timestamp = root.timestamp.loose(),
                  let date = ISO8601.parse(timestamp) else { return nil }

            // The same assistant message is replayed into resumed and forked transcripts, so
            // identity comes from the message id paired with the request that produced it.
            let messageId = message.id.loose() ?? ""
            let requestId = root.requestId.loose() ?? ""
            let key: String
            if messageId.isEmpty, requestId.isEmpty {
                // Nothing stable to dedupe on; fall back to the line's own uuid.
                key = "uuid:\(root.uuid.loose() ?? UUID().uuidString)"
            } else {
                key = "\(messageId)|\(requestId)"
            }

            return ObservedRequest(
                key: key,
                timestamp: date,
                model: model,
                tokens: tokens,
                // Fast mode bills at a multiple of the Standard rates. Anything other than an
                // explicit "fast", including a line written before the field existed, is Standard.
                isFast: usage.speed.loose()?.lowercased() == "fast"
            )
        }
    }

    /// The fields of a transcript line the adapter reads. Everything else is skipped unparsed.
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
            let speed: LooseValue<String>?
        }

        struct CacheCreation: Decodable {
            let ephemeral_1h_input_tokens: LooseScalar?
        }
    }
}
