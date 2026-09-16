import Foundation
import QuotaBarCore
import SQLite3

enum CostDatabaseLocationTests {
    static func run() throws {
        try self.migratesWALDatabase()
        try self.keepsExistingDestination()
        try self.doesNothingWithoutSource()
    }

    static func runSchemaMigration() async throws {
        try await self.upgradesLegacyUsageSchema()
    }

    private static func migratesWALDatabase() throws {
        try self.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("legacy/cost-usage.sqlite")
            let destination = directory.appendingPathComponent("durable/cost-usage.sqlite")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var sourceDatabase: OpaquePointer?
            guard sqlite3_open(source.path, &sourceDatabase) == SQLITE_OK, let sourceDatabase else {
                throw TestError.sqlite("Could not open WAL fixture")
            }
            defer { sqlite3_close(sourceDatabase) }

            try self.execute("PRAGMA journal_mode=WAL", on: sourceDatabase)
            try self.execute("PRAGMA wal_autocheckpoint=0", on: sourceDatabase)
            try self.execute("CREATE TABLE usage (tokens INTEGER NOT NULL)", on: sourceDatabase)
            try self.execute("INSERT INTO usage VALUES (42)", on: sourceDatabase)

            let wal = URL(fileURLWithPath: source.path + "-wal")
            let walSize = try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            Harness.expect(walSize > 0, "legacy fixture keeps committed data in WAL")

            try CostDatabaseLocation.migrateIfNeeded(from: source, to: destination)

            Harness.expect(FileManager.default.fileExists(atPath: source.path), "migration leaves the legacy database intact")
            Harness.expectEqual(try self.readTokens(from: destination), 42, "migration includes committed WAL data")
        }
    }

    private static func keepsExistingDestination() throws {
        try self.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("legacy.sqlite")
            let destination = directory.appendingPathComponent("cost-usage.sqlite")
            try Data("legacy".utf8).write(to: source)
            let existing = Data("existing".utf8)
            try existing.write(to: destination)

            try CostDatabaseLocation.migrateIfNeeded(from: source, to: destination)

            Harness.expectEqual(try Data(contentsOf: destination), existing, "existing destination wins")
            Harness.expectEqual(try Data(contentsOf: source), Data("legacy".utf8), "existing destination leaves source intact")
        }
    }

    private static func doesNothingWithoutSource() throws {
        try self.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("missing/cost-usage.sqlite")
            let destination = directory.appendingPathComponent("durable/cost-usage.sqlite")

            try CostDatabaseLocation.migrateIfNeeded(from: source, to: destination)

            Harness.expect(!FileManager.default.fileExists(atPath: destination.path), "missing source creates no database")
            Harness.expect(
                !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path),
                "missing source creates no destination directory"
            )
        }
    }

    private static func upgradesLegacyUsageSchema() async throws {
        try await self.withTemporaryDirectory { directory in
            let database = directory.appendingPathComponent("cost-usage.sqlite")
            try self.createLegacyUsageDatabase(at: database)

            let missingHome = directory.appendingPathComponent("missing-codex-home")
            let env = [
                "CODEX_HOME": missingHome.path,
                "XDG_DATA_HOME": directory.appendingPathComponent("missing-xdg-home").path,
                "PI_CODING_AGENT_DIR": directory.appendingPathComponent("missing-pi-home").path,
            ]
            let overlay = PricingOverlay(userOverrides: [
                "migration-model": ModelPricing(input: 1, output: 2),
            ])
            let service = CostService(databaseURL: database, env: env, pricingOverlay: overlay)

            let retained = await service.refresh(.codex)
            Harness.expect(retained != nil, "legacy schema opens when all source sessions are absent")
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM codex_day WHERE path = '/missing/legacy-rollout.jsonl' "
                        + "AND is_fast = 0 AND input = 10 AND output = 2 AND cache_write = 3 "
                        + "AND cache_write_1h = 1 AND cache_read = 4 "
                        + "AND cost_usd = 1.25 AND unpriced_tokens = 6",
                    from: database
                ),
                1,
                "legacy Codex usage and frozen price survive schema upgrade"
            )
            Harness.expectEqual(
                try self.scalarInt(
                    "SELECT COUNT(*) FROM opencode_part WHERE key = 'legacy-part' "
                        + "AND is_fast = 0 AND input = 5 AND cost_usd = 0.75",
                    from: database
                ),
                1,
                "legacy OpenCode usage survives with the standard tier"
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
            PRAGMA user_version = 6;
            """, on: connection)
    }

    private static func readTokens(from database: URL) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw TestError.sqlite("Could not open migrated database")
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT tokens FROM usage", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite("Could not query migrated database")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.sqlite("Migrated database contains no usage row")
        }
        return Int(sqlite3_column_int64(statement, 0))
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

    private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cost-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cost-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private enum TestError: Error {
        case sqlite(String)
    }
}
