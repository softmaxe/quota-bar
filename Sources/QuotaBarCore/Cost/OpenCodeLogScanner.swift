import Foundation
import SQLite3

enum OpenCodeLogScanner {
    struct Result {
        let touched: Int
        let status: OpenCodeScanStatus
    }

    private struct AuthFile: Decodable {
        let openai: OpenAI?

        struct OpenAI: Decodable {
            let type: String?
            let accountId: String?
        }
    }

    private struct Row {
        let key: String
        let day: String
        let model: String
        let isFast: Bool
        let totals: TokenTotals
    }

    private struct FastToggle {
        let created: Double
        let isFast: Bool
    }

    static func scan(cache: CostCache, overlay: PricingOverlay?, env: [String: String]) -> Result {
        let dataDirectory = self.dataDirectory(env: env)
        let databaseURL = dataDirectory.appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Result(touched: 0, status: .idle)
        }

        let eligibility = self.eligibility(dataDirectory: dataDirectory, env: env)
        guard case .indeterminate = eligibility else {
            return self.scanDatabase(
                databaseURL,
                eligibility: eligibility,
                cache: cache,
                overlay: overlay
            )
        }
        return Result(touched: 0, status: .error("auth"))
    }

    private static func scanDatabase(
        _ url: URL,
        eligibility: ExternalAgentEligibility,
        cache: CostCache,
        overlay: PricingOverlay?
    ) -> Result {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return Result(touched: 0, status: .error("database"))
        }
        defer { sqlite3_close(db) }

        do {
            try self.validateSchema(db)
            try self.exec(db, "BEGIN")
            let rows = try self.readRows(db)
            try self.exec(db, "COMMIT")

            guard let (included, status) = eligibility.resolved else {
                return Result(touched: 0, status: .error("auth"))
            }

            let backfillCompleted = try cache.hasCompletedOpenCodeBackfill()
            let legacy = included && !backfillCompleted
            try cache.beginTransaction()
            do {
                for row in rows {
                    let model = CostPricing.normalizeCodexModel(row.model)
                    let serviceTier: CostPricing.CodexServiceTier = row.isFast ? .fast : .standard
                    let pricing = CostPricing.pricing(
                        forNormalizedModel: model,
                        provider: .codex,
                        overlay: overlay,
                        codexServiceTier: serviceTier
                    )
                    let longContext = CostPricing.isLongContext(totals: row.totals, pricing: pricing)
                    let cost = pricing?.cost(for: row.totals, longContext: longContext)
                    try cache.addOpenCodePart(
                        key: row.key,
                        included: included,
                        legacyInferred: legacy,
                        day: row.day,
                        model: model,
                        longContext: longContext,
                        isFast: row.isFast,
                        totals: row.totals,
                        costUSD: cost
                    )
                }
                if legacy { try cache.markOpenCodeBackfillComplete() }
                try cache.commit()
            } catch {
                cache.rollback()
                throw error
            }
            return Result(touched: rows.count, status: status)
        } catch {
            try? self.exec(db, "ROLLBACK")
            return Result(touched: 0, status: .error("schema"))
        }
    }

    private static func eligibility(
        dataDirectory: URL,
        env: [String: String]
    ) -> ExternalAgentEligibility {
        do {
            let openCodeData = try Data(contentsOf: dataDirectory.appendingPathComponent("auth.json"))
            let codexAccountId = try CodexCredentialsStore.accountId(env: env)
            guard let openCode = try JSONDecoder()
                .decode(AuthFile.self, from: openCodeData).openai else { return .indeterminate }
            return .matchingCodexAccount(
                type: openCode.type,
                accountId: openCode.accountId,
                codexAccountId: codexAccountId
            )
        } catch {
            return .indeterminate
        }
    }

    private static func dataDirectory(env: [String: String]) -> URL {
        if let explicit = env["OPENCODE_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        let home = env["HOME"].flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    private static func validateSchema(_ db: OpaquePointer) throws {
        for table in ["part", "message"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw ScanError.schema
            }
            var columns = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                columns.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            let required: Set<String> = table == "part" ? ["id", "message_id", "data"] : ["id", "data"]
            guard required.isSubset(of: columns) else { throw ScanError.schema }
        }
    }

    private static func readRows(_ db: OpaquePointer) throws -> [Row] {
        // Native OpenAI responses can leave the effective tier in part metadata. The
        // opencodex-fast plugin injects the request after that metadata is built, so its ignored
        // ON/OFF messages are the only durable state signal and act as a fallback.
        let fastToggles = try self.readFastToggles(db)
        let sql = """
        SELECT p.id,
               json_extract(m.data, '$.time.created'),
               json_extract(m.data, '$.modelID'),
               json_extract(p.data, '$.tokens.input'),
               json_extract(p.data, '$.tokens.output'),
               json_extract(p.data, '$.tokens.reasoning'),
               json_extract(p.data, '$.tokens.cache.read'),
               json_extract(p.data, '$.tokens.cache.write'),
               COALESCE(
                   json_extract(m.data, '$.serviceTier'),
                   json_extract(m.data, '$.service_tier'),
                   (
                       SELECT COALESCE(
                           json_extract(mp.data, '$.metadata.openai.serviceTier'),
                           json_extract(mp.data, '$.metadata.openai.service_tier')
                       )
                       FROM part mp
                       WHERE mp.message_id = m.id
                         AND COALESCE(
                             json_extract(mp.data, '$.metadata.openai.serviceTier'),
                             json_extract(mp.data, '$.metadata.openai.service_tier')
                         ) IS NOT NULL
                       ORDER BY mp.id DESC
                       LIMIT 1
                   )
               )
        FROM part p
        JOIN message m ON m.id = p.message_id
        WHERE json_extract(p.data, '$.type') = 'step-finish'
          AND json_extract(m.data, '$.providerID') = 'openai'
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ScanError.schema }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(stmt, 0),
                  let modelText = sqlite3_column_text(stmt, 2) else { continue }
            let input = max(0, Int(sqlite3_column_int64(stmt, 3)))
            let output = max(0, Int(sqlite3_column_int64(stmt, 4)))
                + max(0, Int(sqlite3_column_int64(stmt, 5)))
            let cacheRead = max(0, Int(sqlite3_column_int64(stmt, 6)))
            let cacheWrite = max(0, Int(sqlite3_column_int64(stmt, 7)))
            let totals = TokenTotals(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
            guard totals.total > 0 else { continue }
            let rawTime = sqlite3_column_double(stmt, 1)
            let seconds = rawTime > 10_000_000_000 ? rawTime / 1000 : rawTime
            guard seconds > 0 else { continue }
            let explicitTier = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            rows.append(Row(
                key: String(cString: keyText),
                day: DayKey.make(from: Date(timeIntervalSince1970: seconds)),
                model: String(cString: modelText),
                isFast: explicitTier.map { CostPricing.CodexServiceTier.parse($0).isFast }
                    ?? self.fastMode(at: rawTime, toggles: fastToggles),
                totals: totals
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw ScanError.read }
        return rows
    }

    private static func readFastToggles(_ db: OpaquePointer) throws -> [FastToggle] {
        let sql = """
        SELECT json_extract(m.data, '$.time.created'), json_extract(p.data, '$.text')
        FROM message m
        JOIN part p ON p.message_id = m.id
        WHERE json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
          AND json_extract(p.data, '$.ignored') = 1
          AND json_extract(p.data, '$.text') IN ('Fast mode is now ON.', 'Fast mode is now OFF.')
        ORDER BY 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ScanError.schema }
        var toggles: [FastToggle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 1) else { continue }
            toggles.append(FastToggle(
                created: sqlite3_column_double(stmt, 0),
                isFast: String(cString: text) == "Fast mode is now ON."
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw ScanError.read }
        return toggles
    }

    private static func fastMode(at created: Double, toggles: [FastToggle]) -> Bool {
        var lower = 0
        var upper = toggles.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if toggles[middle].created <= created {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 && toggles[lower - 1].isFast
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ScanError.read }
    }

    private enum ScanError: Error { case schema, read }
}
