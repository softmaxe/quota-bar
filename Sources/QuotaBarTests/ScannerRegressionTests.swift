import QuotaBarCore
import Foundation
import SQLite3

enum ScannerRegressionTests {
    static func run() async {
        Self.unchangedPartialLineDoesNotRequireRescan()
        await Self.codexResumeStatePersists()
        if ProcessInfo.processInfo.environment["QUOTABAR_SCANNER_BENCHMARK"] == "1" {
            await Self.benchmarkCodexAppend()
        }
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
            pricingOverlay: PricingOverlay()
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
        let restored = await CostService(databaseURL: database, env: env, pricingOverlay: PricingOverlay())
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
        let resumed = await CostService(databaseURL: database, env: env, pricingOverlay: PricingOverlay())
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
        let replayed = await CostService(databaseURL: database, env: env, pricingOverlay: PricingOverlay())
            .refresh(.codex)
        Harness.expectEqual(replayed?.windowTokens, 2, "a missing resume state still filters a replayed token count")

        let replacementContext = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-5.6-luna"}}"#
        try? ([replacementContext, event(last: 3, total: 3)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let rewritten = await CostService(databaseURL: database, env: env, pricingOverlay: PricingOverlay())
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

    private static func benchmarkCodexAppend() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-scanner-benchmark-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let file = codexHome.appendingPathComponent("sessions/rollout.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let context = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-5.6-luna"}}"#
        let fillerLine = #"{"type":"response_item","payload":{"type":"message","text":"fixture"}}"# + "\n"
        let filler = Data(String(repeating: fillerLine, count: 1_000).utf8)
        FileManager.default.createFile(atPath: file.path, contents: Data((context + "\n").utf8))
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        for _ in 0..<900 { try? handle.write(contentsOf: filler) }
        try? handle.close()

        let env = Self.isolatedEnvironment(root: root, codexHome: codexHome)
        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: env,
            pricingOverlay: PricingOverlay()
        )
        let cold = await service.refresh(.codex)
        var correct = cold != nil && cold?.windowTokens == 0

        var durations: [Double] = []
        for turn in 1...5 {
            let event = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":\#(turn),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"# + "\n"
            guard let append = try? FileHandle(forWritingTo: file) else { return }
            _ = try? append.seekToEnd()
            try? append.write(contentsOf: Data(event.utf8))
            try? append.close()

            let start = ContinuousClock.now
            let snapshot = await service.refresh(.codex)
            let elapsed = start.duration(to: .now)
            correct = correct && snapshot?.windowTokens == turn
            durations.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            )
        }
        let sorted = durations.sorted()
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.doubleValue ?? 0
        print(String(
            format: "scanner_fixture_mb=%.1f correct=%@ append_ms_median=%.1f min=%.1f max=%.1f",
            size / 1_048_576,
            correct ? "yes" : "no",
            sorted[sorted.count / 2],
            sorted.first ?? 0,
            sorted.last ?? 0
        ))
        Harness.expect(correct, "the scanner benchmark validates every incremental snapshot")
    }
}
