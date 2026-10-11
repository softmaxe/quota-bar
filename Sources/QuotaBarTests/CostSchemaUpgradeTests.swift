import Foundation
import QuotaBarCore
import SQLite3

/// Databases written by 1.0.7 and earlier stored frozen costs. Opening one upgrades it in place
/// without losing usage whose source logs are gone.
enum CostSchemaUpgradeTests {
    static func run() async throws {
        try await self.upgradesLegacyUsageSchema()
    }

    private static func upgradesLegacyUsageSchema() async throws {
        try await self.withTemporaryDirectory { directory in
            let database = directory.appendingPathComponent("cost-usage.sqlite")
            try self.createLegacyUsageDatabase(at: database)

            let missingHome = directory.appendingPathComponent("missing-codex-home")
            let claudeHome = directory.appendingPathComponent("missing-claude-home")
            let env = isolatedEnvironment(root: directory, overriding: [
                "CODEX_HOME": missingHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path,
            ])
            let rateCard = RateCard(overrides: [
                "migration-model": ModelPricing(input: 1, output: 2),
            ])
            let service = CostService(databaseURL: database, env: env, rateCard: rateCard)

            let retained = await service.refresh(.codex)
            Harness.expect(retained != nil, "legacy schema opens when all source sessions are absent")
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM codex_day WHERE path = '/missing/legacy-rollout.jsonl' "
                        + "AND is_fast = 0 AND input = 10 AND output = 2 AND cache_write = 3 "
                        + "AND cache_write_1h = 1 AND cache_read = 4",
                    from: database
                ),
                1,
                "legacy Codex usage survives schema upgrade"
            )
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM opencode_part WHERE key = 'legacy-part' "
                        + "AND is_fast = 0 AND input = 5",
                    from: database
                ),
                1,
                "legacy OpenCode usage survives with the standard tier"
            )
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM claude_message WHERE key = 'legacy-message' "
                        + "AND is_fast = 0 AND cache_write_1h = 0 AND input = 7 AND output = 3",
                    from: database
                ),
                1,
                "legacy Claude usage survives with the standard tier"
            )
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM file_cursor WHERE path = '/missing/legacy-rollout.jsonl'",
                    from: database
                ),
                1,
                "legacy cursor survives schema upgrade"
            )

            let session = missingHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent("rollout-2026-09-05T12-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try FileManager.default.createDirectory(
                at: session.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let lines = [
                #"{"type":"turn_context","payload":{"model":"migration-model","service_tier":"fast"}}"#,
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}"#,
            ].joined(separator: "\n") + "\n"
            try lines.write(to: session, atomically: true, encoding: .utf8)

            let updated = await service.refresh(.codex)
            Harness.expect(updated != nil, "scanner writes to the rebuilt Codex primary key")
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM codex_day WHERE model = 'migration-model' AND is_fast = 1",
                    from: database
                ),
                1,
                "subsequent scanner write records the fast tier"
            )

            let transcript = claudeHome.appendingPathComponent("projects/app/session.jsonl")
            try FileManager.default.createDirectory(
                at: transcript.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let claudeLine = #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-fast","message":{"id":"msg-fast","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":2,"speed":"fast"}}}"#
            try (claudeLine + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            let claude = await service.refresh(.claude)
            Harness.expect(claude != nil, "scanner writes to the upgraded Claude table")
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM claude_message WHERE key = 'msg-fast|req-fast' AND is_fast = 1",
                    from: database
                ),
                1,
                "subsequent Claude scanner write records Fast mode"
            )
        }
    }

    private static func createLegacyUsageDatabase(at database: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else {
            throw TestError.sqlite("Could not open legacy schema fixture")
        }
        defer { sqlite3_close(connection) }
        try self.execute("""
            CREATE TABLE file_cursor (
                path TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                inode INTEGER NOT NULL,
                size INTEGER NOT NULL,
                offset INTEGER NOT NULL,
                prefix_digest TEXT NOT NULL
            );
            INSERT INTO file_cursor VALUES ('/missing/legacy-rollout.jsonl', 'codex', 1, 100, 100, 'digest');

            CREATE TABLE codex_day (
                path TEXT NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                long_context INTEGER NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_write INTEGER NOT NULL,
                cache_read INTEGER NOT NULL,
                cost_usd REAL,
                unpriced_tokens INTEGER,
                cache_write_1h INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (path, day, model, long_context)
            );
            INSERT INTO codex_day VALUES (
                '/missing/legacy-rollout.jsonl', '2026-09-05', 'legacy-model', 0,
                10, 2, 3, 4, 1.25, 6, 1
            );

            CREATE TABLE opencode_part (
                key TEXT PRIMARY KEY,
                included INTEGER NOT NULL,
                legacy_inferred INTEGER NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                long_context INTEGER NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_write INTEGER NOT NULL,
                cache_write_1h INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                unpriced_tokens INTEGER NOT NULL
            );
            INSERT INTO opencode_part VALUES (
                'legacy-part', 1, 0, '2026-09-05', 'legacy-opencode-model', 0,
                5, 1, 0, 0, 0, 0.75, 0
            );
            CREATE TABLE claude_message (
                key TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                long_context INTEGER NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_write INTEGER NOT NULL,
                cache_read INTEGER NOT NULL,
                cost_usd REAL,
                unpriced_tokens INTEGER
            );
            INSERT INTO claude_message VALUES (
                'legacy-message', '/missing/legacy-session.jsonl', '2026-09-05', 'claude-opus-5-5', 0,
                7, 3, 0, 0, 0.5, 0
            );
            CREATE INDEX opencode_part_unpriced ON opencode_part(cost_usd)
                WHERE cost_usd IS NULL OR unpriced_tokens IS NULL;
            PRAGMA user_version = 6;
            """, on: connection)
    }

    private static func scalarInt(_ sql: String, from database: URL) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw TestError.sqlite("Could not open usage database")
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw TestError.sqlite(message)
        }
    }

    private static func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cost-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private enum TestError: Error {
        case sqlite(String)
    }
}
