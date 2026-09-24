import QuotaBarCore
import Foundation
import SQLite3

enum ScannerRegressionTests {
    static func run() async {
        Self.unchangedPartialLineDoesNotRequireRescan()
        Self.sameSizeRewriteRequiresReparse()
        await Self.codexResumeStatePersists()
        await Self.claudeFieldTypesMatchLooseCasts()
    }

    /// Prefix digests are reused while a file is untouched. An in-place rewrite that keeps the
    /// size and inode must still be recognised as a rewrite.
    private static func sameSizeRewriteRequiresReparse() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-rewrite-plan-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("rewrite.jsonl")
        try? "first\n".write(to: file, atomically: false, encoding: .utf8)
        guard let initial = try? LogFileScanner.plan(for: file, previous: nil) else {
            Harness.expect(false, "a new log produces a scan plan")
            return
        }
        let previous = FileCursor(
            inode: initial.cursor.inode,
            size: initial.cursor.size,
            offset: initial.cursor.size,
            prefixDigest: initial.cursor.prefixDigest
        )
        let unchanged = try? LogFileScanner.plan(for: file, previous: previous)
        Harness.expectEqual(unchanged?.requiresScan, false, "an untouched log is not rescanned")

        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.write(contentsOf: Data("other\n".utf8))
            try? handle.close()
        }
        let rewritten = try? LogFileScanner.plan(for: file, previous: previous)
        Harness.expectEqual(rewritten?.cursor.inode, initial.cursor.inode, "the rewrite keeps the inode")
        Harness.expectEqual(rewritten?.requiresFullReparse, true, "a same-size rewrite forces a reparse")
    }

    /// Claude lines are decoded into typed fields. A field of an unexpected type must read as it
    /// did through `JSONSerialization`: numeric strings count, other types are absent, and the
    /// rest of the line still counts.
    private static func claudeFieldTypesMatchLooseCasts() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-claude-fields-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent("claude")
        let file = claudeHome.appendingPathComponent("projects/app/session.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let lines = [
            // Numeric strings and doubles count; a non-object cache_creation reads as absent; a
            // numeric message id reads as empty, so the request id alone identifies the message.
            #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-1","message":{"id":7,"model":" claude-opus-5-20260101 ","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":"10","output_tokens":20.9,"cache_creation_input_tokens":30,"cache_read_input_tokens":true,"cache_creation":5}}}"#,
            // A replay of the same request with no more output does not add a second message.
            #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-1","message":{"id":"","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":1}}}"#,
            // A non-string type or model skips the line.
            #"{"type":1,"timestamp":"\#(timestamp)","requestId":"req-2","message":{"model":"claude-opus-5","usage":{"input_tokens":1000}}}"#,
            #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-3","message":{"model":5,"usage":{"input_tokens":1000}}}"#,
            // A usage that is not an object skips the line.
            #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-4","message":{"model":"claude-opus-5","usage":[1]}}"#,
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: ["CLAUDE_CONFIG_DIR": claudeHome.path],
            rateCard: RateCard()
        )
        let snapshot = await service.refresh(.claude)
        let tokens = snapshot?.days.first?.tokens
        Harness.expectEqual(tokens?.input, 10, "a numeric-string input count is read")
        Harness.expectEqual(tokens?.output, 20, "a fractional output count truncates")
        Harness.expectEqual(tokens?.cacheWrite, 30, "cache writes are read")
        Harness.expectEqual(tokens?.cacheWrite1h, 0, "a non-object cache_creation reads as absent")
        Harness.expectEqual(tokens?.cacheRead, 1, "a boolean count reads as its number")
        Harness.expectEqual(snapshot?.windowTokens, 61, "mistyped lines are skipped and replays deduped")
        Harness.expectEqual(snapshot?.topModel, "claude-opus-5", "the model is trimmed and normalized")
    }

    private static func unchangedPartialLineDoesNotRequireRescan() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-scan-plan-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("partial.jsonl")
        try? "complete\npartial".write(to: file, atomically: true, encoding: .utf8)
        guard let initial = try? LogFileScanner.plan(for: file, previous: nil) else {
            Harness.expect(false, "a new partial log produces a scan plan")
            return
        }
        let offset = try? LogFileScanner.readLines(of: file, from: 0) { _ in }
        let previous = FileCursor(
            inode: initial.cursor.inode,
            size: initial.cursor.size,
            offset: offset ?? -1,
            prefixDigest: initial.cursor.prefixDigest
        )
        let unchanged = try? LogFileScanner.plan(for: file, previous: previous)
        Harness.expectEqual(unchanged?.requiresScan, false, "an unchanged partial line is not rescanned")

        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n".utf8))
            try? handle.close()
        }
        let appended = try? LogFileScanner.plan(for: file, previous: previous)
        Harness.expectEqual(appended?.requiresScan, true, "an appended newline resumes the deferred line")
    }

    private static func codexResumeStatePersists() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-resume-state-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let file = codexHome.appendingPathComponent("sessions/rollout.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let context = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-5.6-sol","service_tier":"priority"}}"#
        func event(last: Int = 1, total: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(last),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#
        }
        try? ([context, event(total: 1)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("cache.sqlite")
        let env = Self.isolatedEnvironment(root: root, codexHome: codexHome)
        var service: CostService? = CostService(
            databaseURL: database,
            env: env,
            rateCard: RateCard()
        )
        let initial = await service?.refresh(.codex)
        Harness.expectEqual(initial?.windowTokens, 1, "the initial Codex turn is scanned")
        Harness.expectEqual(initial?.days.first?.rankedModels.first?.key.isFast, true, "the initial Fast tier is scanned")
        service = nil
        Harness.expect(Self.hasStoredResumeState(database: database), "the Codex cursor stores its resume state")

        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((event(total: 1) + "\n").utf8))
            try? handle.close()
        }
        let restored = await CostService(databaseURL: database, env: env, rateCard: RateCard())
            .refresh(.codex)
        Harness.expectEqual(restored?.windowTokens, 1, "a persisted cursor filters a replayed token count")
        Harness.expectEqual(restored?.topModel, "gpt-5.6-sol", "a persisted cursor keeps the active model")
        Harness.expectEqual(restored?.days.first?.rankedModels.first?.key.isFast, true, "a persisted cursor keeps the Fast tier")

        Harness.expect(
            Self.updateResumeState(database: database, value: "not-json"),
            "the test corrupts the stored resume state"
        )
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((event(total: 2) + "\n").utf8))
            try? handle.close()
        }
        let resumed = await CostService(databaseURL: database, env: env, rateCard: RateCard())
            .refresh(.codex)
        Harness.expectEqual(resumed?.windowTokens, 2, "a corrupt resume state falls back to prefix replay")
        Harness.expectEqual(resumed?.topModel, "gpt-5.6-sol", "prefix replay recovers the active model")
        Harness.expectEqual(resumed?.days.first?.rankedModels.first?.key.isFast, true, "prefix replay recovers the Fast tier")

        Harness.expect(
            Self.updateResumeState(database: database, value: nil),
            "the test clears the stored resume state"
        )
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((event(total: 2) + "\n").utf8))
            try? handle.close()
        }
        let replayed = await CostService(databaseURL: database, env: env, rateCard: RateCard())
            .refresh(.codex)
        Harness.expectEqual(replayed?.windowTokens, 2, "a missing resume state still filters a replayed token count")

        let replacementContext = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-5.6-luna"}}"#
        try? ([replacementContext, event(last: 3, total: 3)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let rewritten = await CostService(databaseURL: database, env: env, rateCard: RateCard())
            .refresh(.codex)
        Harness.expectEqual(rewritten?.windowTokens, 3, "a rewritten file drops usage derived from its old cursor")
        Harness.expectEqual(rewritten?.topModel, "gpt-5.6-luna", "a rewritten file drops its persisted model")
        Harness.expectEqual(rewritten?.days.first?.rankedModels.first?.key.isFast, false, "a rewritten file drops its Fast tier")
    }

    private static func hasStoredResumeState(database: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM file_cursor WHERE resume_state IS NOT NULL AND length(resume_state) > 0",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func updateResumeState(database: URL, value: String?) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE file_cursor SET resume_state = ?", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        if let value {
            sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, 1)
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func isolatedEnvironment(root: URL, codexHome: URL) -> [String: String] {
        [
            "CODEX_HOME": codexHome.path,
            "HOME": root.path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg").path,
            "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path,
        ]
    }
}
