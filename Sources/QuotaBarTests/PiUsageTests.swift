import Foundation
import JavaScriptCore
import QuotaBarCore

/// Pi attribution, pricing, fork identity and portable history exercised through real logs/SQLite.
enum PiUsageTests {
    static func run() async {
        do {
            try await self.providersAndPricing()
            try await self.routedAnthropicNames()
            try self.entryKindsAndForks()
            try await self.migrationAndBackups()
            try await self.backupRevisionConsistency()
            try self.reportModelMerge()
        } catch {
            Harness.expect(false, "Pi usage tests threw: \(error)")
        }
    }

    private static let card = RateCard.fixture(
        codex: ["gpt-test": ModelPricing(input: 2, output: 4),
                "claude-test": ModelPricing(input: 99, output: 99)],
        claude: ["claude-test": ModelPricing(input: 3, output: 6)],
        thirdParty: ["gemini-test": ModelPricing(input: 4, output: 8)]
    )

    private static func line(
        _ id: String, provider: String? = "openai-codex", model: String = "gpt-test",
        milliseconds: Int64, input: Int = 1_000_000, cost: Any? = nil, reported: Bool? = nil,
        type: String = "message", attributed: Bool = true
    ) throws -> String {
        var usage: [String: Any] = ["input": input, "output": 0, "cacheRead": 0, "cacheWrite": 0]
        if let cost {
            var amount: [String: Any] = ["total": cost]
            if let reported { amount["totalFromProvider"] = reported }
            usage["cost"] = amount
        }
        var data: [String: Any] = ["usage": usage]
        if attributed { data["provider"] = provider; data["model"] = model }
        var entry: [String: Any] = ["type": type, "id": id,
                                   "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))]
        if type == "message" {
            data["role"] = "assistant"
            data["timestamp"] = milliseconds
            entry["message"] = data
        } else {
            entry.merge(data) { _, new in new }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func providersAndPricing() async throws {
        let fixture = RecorderFixture(name: "pi-upstreams")
        defer { fixture.remove() }
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        var lines = try [
            self.line("subscription", milliseconds: ms, cost: 999),
            self.line("api", provider: "openai", model: "openai/gpt-test", milliseconds: ms, cost: 999),
            self.line("anthropic", provider: "anthropic", model: "claude-test", milliseconds: ms, cost: 999),
            self.line("router", provider: "openrouter", model: "anthropic/claude-test", milliseconds: ms, cost: 999),
            self.line("google", provider: "google", model: "google/gemini-test", milliseconds: ms, cost: 999),
            self.line("fallback", provider: "groq", model: "unlisted", milliseconds: ms, cost: 1.25, reported: true),
            self.line("estimate", provider: "groq", model: "catalog-only", milliseconds: ms, cost: 0.75, reported: false),
        ]
        // These share one model/provider bucket with the valid fallback: partial cost must not
        // accidentally price their tokens just because another request supplied a total.
        for (id, cost) in [("zero", 0 as Any), ("negative", -1 as Any), ("string", "2" as Any),
                           ("bool", true as Any), ("missing", NSNull() as Any)] {
            lines.append(try self.line(id, provider: "groq", model: "unlisted", milliseconds: ms, cost: cost))
        }
        lines.append(try self.line("absent", provider: "groq", model: "no-cost", milliseconds: ms))
        PiSessionFile.write(root: fixture.root, "project/all.jsonl", lines: lines)
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: self.card)
        let codex = await service.refresh(.codex)
        Harness.expectEqual(codex?.windowTokens, 0, "Codex does not scan or count Pi requests")
        let snapshot = await service.refresh(.pi)
        Harness.expectEqual(snapshot?.tab, .pi, "the Pi snapshot identifies its usage tab")
        Harness.expectEqual(snapshot?.windowTokens, lines.count * 1_000_000, "every Pi upstream counts with no sign-in files")
        Harness.expectClose(snapshot?.windowCostUSD, 16, "model maker prices override logged cost, then positive totals supply fallbacks")
        let day = snapshot?.days.last
        Harness.expectEqual(day?.unpricedTokens, 6_000_000, "zero, missing and invalid costs remain unpriced in a partly priced bucket")
        let models = day?.byModel ?? [:]
        Harness.expectEqual(models[ModelUsageKey(source: .piAgent, model: "claude-test", upstreamProvider: "openrouter")]?.costUSD, 3,
                            "a vendor-prefixed Anthropic model uses the Claude book")
        Harness.expectEqual(models[ModelUsageKey(source: .piAgent, model: "gpt-test", upstreamProvider: "openai")]?.costUSD, 2,
                            "an API OpenAI request uses the Codex book")
        Harness.expectEqual(models.keys.filter { $0.model == "claude-test" }.count, 2,
                            "same-model upstream providers stay separate")
        Harness.expectEqual(models[ModelUsageKey(source: .piAgent, model: "unlisted", upstreamProvider: "groq")]?.usesLoggedCostFallback, true,
                            "the model entry exposes its logged-cost fallback")
        Harness.expectEqual(models[ModelUsageKey(source: .piAgent, model: "gpt-test", upstreamProvider: "openai-codex")]?.usesLoggedCostFallback, false,
                            "subscription usage uses API token rates, not logged cost")
        let db = try TestDatabase(fixture.databaseURL)
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE raw_model = 'anthropic/claude-test' AND upstream_provider = 'openrouter'"), 1,
                            "storage preserves the full upstream model ID")
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE total_from_provider = 1 AND logged_total_usd = 1.25"), 1,
                            "provider-reported cost provenance is stored")
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE total_from_provider = 0 AND logged_total_usd = 0.75"), 1,
                            "catalog-estimated cost provenance is stored")
        let report = try UsageReportReader.read(databaseURL: fixture.databaseURL, now: now, rateCard: self.card)
        let reportDay = report.days.last!
        Harness.expectEqual(reportDay.sources.map(\.source), ["piAgent"], "all upstreams appear under the Pi Agent report source")
        Harness.expectEqual(reportDay.models.filter { $0.name == "claude-test" }.count, 2,
                            "the report retains the upstream split")
        Harness.expectClose(reportDay.cost, snapshot?.windowCostUSD ?? -1, "report and menu agree on fallback costs")
        let literal = try UsageReportHTMLRenderer.scriptLiteral(report)
        Harness.expect(literal.contains("\"upstreamProvider\":\"openrouter\""), "HTML and live-update JSON retain the upstream provider")
        let backup = fixture.root.appendingPathComponent("usage-backup.sqlite")
        try await service.exportBackup(to: backup)
        let restoredRoot = fixture.root.appendingPathComponent("restored")
        let restoredURL = restoredRoot.appendingPathComponent("usage.sqlite")
        let restored = CostService(databaseURL: restoredURL, env: isolatedEnvironment(root: restoredRoot), rateCard: self.card)
        _ = try await restored.importBackup(from: backup)
        let restoredSnapshot = await restored.refresh(.pi)
        Harness.expectEqual(restoredSnapshot?.days, snapshot?.days,
                            "new backup round trip preserves upstream splits, tokens, fallback cost and provenance")
        let restoredDB = try TestDatabase(restoredURL)
        Harness.expectEqual(try restoredDB.scalarInt("SELECT COUNT(*) FROM pi_message WHERE total_from_provider = 1 AND logged_total_usd = 1.25"), 1,
                            "new backups preserve the provider-reported amount and flag")
        Harness.expectEqual(try restoredDB.scalarInt("SELECT COUNT(*) FROM pi_message WHERE total_from_provider IS NULL AND raw_model = 'openai/gpt-test' AND logged_total_usd = 999"), 1,
                            "new backups preserve raw IDs and nullable cost provenance")
        await service.useRateCard(RateCard.fixture(codex: ["unlisted": ModelPricing(input: 1, output: 1)]))
        let repriced = await service.refresh(.pi)
        let entry = repriced?.days.last?.byModel[ModelUsageKey(source: .piAgent, model: "unlisted", upstreamProvider: "groq")]
        Harness.expectClose(entry?.costUSD, 6, "a new rate prices all requests and replaces the fallback without rescanning")
        Harness.expectEqual(entry?.usesLoggedCostFallback, false, "repricing clears fallback provenance")
    }

    private static func routedAnthropicNames() async throws {
        let fixture = RecorderFixture(name: "pi-anthropic-names")
        defer { fixture.remove() }
        let models = ["us.anthropic.claude-sonnet-5", "eu.anthropic.claude-sonnet-5-v1:0",
                      "apac.anthropic.claude-sonnet-5", "global.anthropic.claude-sonnet-5",
                      "anthropic.claude-opus-4-6-v1", "anthropic/claude-sonnet-5.5"]
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        PiSessionFile.write(root: fixture.root, "project/routed.jsonl", lines: try models.enumerated().map { index, model in
            try self.line("routed-\(index)", provider: "amazon-bedrock", model: model, milliseconds: ms, cost: 99)
        })
        let card = RateCard.fixture(claude: ["claude-sonnet-5": ModelPricing(input: 2, output: 4),
                                            "claude-opus-4-6": ModelPricing(input: 5, output: 10),
                                            "claude-sonnet-5-5": ModelPricing(input: 3, output: 6)])
        let service = CostService(databaseURL: fixture.databaseURL, env: fixture.env, rateCard: card)
        let first = await service.refresh(.pi)
        Harness.expectClose(first?.windowCostUSD, 16, "regional Bedrock, versioned and dotted Claude names use the model maker's rates")
        let db = try TestDatabase(fixture.databaseURL)
        try db.exec("UPDATE pi_message SET model = raw_model")
        let reread = await service.refresh(.pi)
        Harness.expectClose(reread?.windowCostUSD, 16, "previously saved raw names resolve at read time without a rescan")
        Harness.expectEqual(Set(reread?.days.flatMap { $0.byModel.keys.map(\.model) } ?? []),
                            ["claude-sonnet-5", "claude-opus-4-6", "claude-sonnet-5-5"], "routed spellings share canonical model IDs")
    }

    private static func entryKindsAndForks() throws {
        let fixture = RecorderFixture(name: "pi-identities")
        defer { fixture.remove() }
        let ms: Int64 = 1_788_264_000_000
        let original = try self.line("deadbeef", milliseconds: ms, input: 10)
        let otherTime = try self.line("deadbeef", milliseconds: ms + 1, input: 20)
        let otherProvider = try self.line("deadbeef", provider: "openai", milliseconds: ms, input: 30)
        let otherModel = try self.line("deadbeef", model: "gpt-other", milliseconds: ms, input: 40)
        PiSessionFile.write(root: fixture.root, "project/original.jsonl", lines: [original])
        PiSessionFile.write(root: fixture.root, "project/fork.jsonl", lines: [original, otherProvider])
        PiSessionFile.write(root: fixture.root, "elsewhere/collision.jsonl", lines: [otherTime, otherModel])
        PiSessionFile.write(root: fixture.root, "project/extra.jsonl", lines: try [
            self.line("usage", provider: "google", model: "gemini-test", milliseconds: ms, input: 5, type: "usage"),
            self.line("compact", milliseconds: ms, input: 6, type: "compaction"),
            self.line("branch", milliseconds: ms, input: 7, type: "branch_summary"),
            self.line("unknown-upstream", provider: nil, milliseconds: ms, input: 8, type: "compaction"),
            self.line("unattributed-compact", milliseconds: ms, input: 99, type: "compaction", attributed: false),
            self.line("unattributed-branch", milliseconds: ms, input: 99, type: "branch_summary", attributed: false),
        ])
        fixture.record(.pi, rateCard: self.card)
        let db = try TestDatabase(fixture.databaseURL)
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message"), 8, "fork copies collapse while short-ID collisions and attributable entry kinds remain distinct")
        Harness.expectEqual(try db.scalarInt("SELECT SUM(input) FROM pi_message"), 126, "summaries with a model count even if the upstream is unknown; summaries without a model are skipped")
        PiSessionFile.write(root: fixture.root, "project/original.jsonl", lines: [try self.line("deadbeef", milliseconds: ms, input: 11)])
        // Remove the stale fork copy so a source snapshot has one authoritative updated response.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("pi/sessions/project/fork.jsonl"))
        fixture.record(.pi, rateCard: self.card)
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message"), 8, "mutable token counts never change a request key")
        Harness.expectEqual(try db.scalarInt("SELECT SUM(input) FROM pi_message"), 127, "a content update replaces usage without changing identity")
    }

    private static func migrationAndBackups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-pi-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.sqlite")
        do {
            _ = try UsageRecorder(databaseURL: oldURL)
            let old = try TestDatabase(oldURL)
            for column in ["upstream_provider", "raw_model", "logged_total_usd", "total_from_provider", "entry_id"] {
                try old.exec("ALTER TABLE pi_message DROP COLUMN \(column)")
            }
            try old.exec("ALTER TABLE pi_message ADD COLUMN cost_usd REAL")
            try old.exec("""
                INSERT INTO pi_message (\(RecordedUsageFixture.piColumns), cost_usd) VALUES
                ('deadbeef', 0, '2026-08-31', 'gpt-test', 0, 10, 0, 0, 0, 0, 999);
                """)
            try old.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            old.close()
        }
        let oldBackup = root.appendingPathComponent("old-backup.sqlite")
        try FileManager.default.copyItem(at: oldURL, to: oldBackup)
        let recorder = try UsageRecorder(databaseURL: oldURL)
        let db = try TestDatabase(oldURL)
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE upstream_provider = 'openai-codex' AND raw_model IS NULL AND logged_total_usd IS NULL"), 1,
                            "legacy migration backfills only the historically known upstream")
        Harness.expectEqual(try recorder.recordedUsageReader.dailyUsage(tab: .pi, fromDay: "2026-01-01").first?.tokens.input, 10,
                            "formerly excluded historical Pi rows now count")
        let ms: Int64 = 1_788_264_000_000
        PiSessionFile.write(root: root, "project/replay.jsonl", lines: [try self.line("deadbeef", milliseconds: ms, input: 10)])
        let env = isolatedEnvironment(root: root)
        recorder.record(.pi, rateCard: self.card, env: env)
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message"), 1, "a legacy replay promotes the old key without adding usage")
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE key LIKE 'pi-v2:%' AND day = '2026-08-31' AND entry_id = 'deadbeef'"), 1,
                            "key promotion preserves the legacy day and short entry ID")
        Harness.expectEqual(try db.scalarInt("SELECT COUNT(*) FROM pi_message WHERE context_input IS NULL"), 1,
                            "key and provenance migration do not backfill unchanged historical request context")
        let service = CostService(databaseURL: oldURL, env: env, rateCard: self.card)
        let oldBackupBytes = try Data(contentsOf: oldBackup)
        let importedOld: UsageImportResult
        do { importedOld = try await service.importBackup(from: oldBackup) }
        catch { throw TestDatabaseError.sqlite("Legacy backup after promotion: \(error)") }
        Harness.expectEqual(importedOld.added, 0, "an old backup imported after promotion does not duplicate the request")
        Harness.expectEqual(try Data(contentsOf: oldBackup), oldBackupBytes,
                            "import never upgrades or modifies the selected old backup itself")
        let modernBackup = root.appendingPathComponent("modern.sqlite")
        try await service.exportBackup(to: modernBackup)
        let restoredURL = root.appendingPathComponent("restored.sqlite")
        let restored = CostService(databaseURL: restoredURL, env: env, rateCard: self.card)
        do { _ = try await restored.importBackup(from: oldBackup) }
        catch { throw TestDatabaseError.sqlite("Legacy backup into fresh database: \(error)") }
        let importedNew: UsageImportResult
        do { importedNew = try await restored.importBackup(from: modernBackup) }
        catch { throw TestDatabaseError.sqlite("Modern backup after legacy: \(error)") }
        Harness.expectEqual(importedNew.added, 0, "a modern backup maps an already-imported legacy key before merging")
        let restoredDB = try TestDatabase(restoredURL)
        Harness.expectEqual(try restoredDB.scalarInt("SELECT COUNT(*) FROM pi_message WHERE raw_model = 'gpt-test' AND entry_id = 'deadbeef' AND upstream_provider = 'openai-codex'"), 1,
                            "modern metadata survives a legacy-first backup merge")
        _ = await restored.refresh(.pi)
        Harness.expectEqual(try restoredDB.scalarInt("SELECT COUNT(*) FROM pi_message"), 1, "restored usage remains deduplicated on its next scan")
        let again = try await restored.importBackup(from: modernBackup)
        Harness.expectEqual(again.added + again.updated, 0, "modern backup import is idempotent")
    }

    private static func backupRevisionConsistency() async throws {
        let local = try RecordedUsageFixture(seed: false)
        let remote = try RecordedUsageFixture(now: local.now, seed: false)
        let columns = RecordedUsageFixture.piColumns + ", context_input, upstream_provider, logged_total_usd, total_from_provider"
        try local.database.exec("""
            INSERT INTO pi_message (\(columns)) VALUES
            ('revision', 1, '\(local.day())', 'custom', 0, 100, 0, 0, 0, 0, 100, 'groq', NULL, NULL),
            ('matching', 1, '\(local.day())', 'custom', 0, 200, 0, 0, 0, 0, 200, 'groq', NULL, NULL),
            ('provenance', 1, '\(local.day())', 'custom', 0, 300, 0, 0, 0, 0, 300, 'groq', 3, NULL);
            """)
        try remote.database.exec("""
            INSERT INTO pi_message (\(columns)) VALUES
            ('revision', 1, '\(local.day())', 'custom', 0, 200, 0, 0, 0, 0, 200, 'groq', 2, 1),
            ('matching', 1, '\(local.day())', 'custom', 0, 200, 0, 0, 0, 0, 200, 'groq', 2, 1),
            ('provenance', 1, '\(local.day())', 'custom', 0, 300, 0, 0, 0, 0, 300, 'groq', 4, 1);
            """)
        let card = RateCard.fixture()
        let source = CostService(databaseURL: remote.databaseURL, env: isolatedEnvironment(root: remote.directory), rateCard: card)
        let backup = remote.directory.appendingPathComponent("backup.sqlite")
        try await source.exportBackup(to: backup)
        let destination = CostService(databaseURL: local.databaseURL, env: isolatedEnvironment(root: local.directory), rateCard: card)
        _ = try await destination.importBackup(from: backup)
        Harness.expectEqual(try local.database.scalarInt("SELECT COUNT(*) FROM pi_message WHERE key = 'revision' AND input = 100 AND context_input = 100 AND logged_total_usd IS NULL AND total_from_provider IS NULL"), 1,
                            "backup never combines a cost with a different revision's usage")
        Harness.expectEqual(try local.database.scalarInt("SELECT COUNT(*) FROM pi_message WHERE key = 'matching' AND input = 200 AND logged_total_usd = 2 AND total_from_provider = 1"), 1,
                            "matching usage can fill an amount and its provenance together")
        Harness.expectEqual(try local.database.scalarInt("SELECT COUNT(*) FROM pi_message WHERE key = 'provenance' AND logged_total_usd = 3 AND total_from_provider IS NULL"), 1,
                            "provenance from another amount cannot describe the local amount")
        let snapshot = try UsageReportReader.read(
            databaseURL: local.databaseURL, now: local.now, calendar: local.calendar, rateCard: card
        )
        Harness.expectClose(snapshot.windowCost, 5, "only costs corresponding to the retained usage are charged")
        Harness.expectEqual(snapshot.days.last?.unpricedTokens, 100, "a mismatched backup leaves the local tokens unpriced")
        let again = try await destination.importBackup(from: backup)
        Harness.expectEqual(again.added + again.updated, 0, "mismatched revision imports remain idempotent")
    }

    private static func reportModelMerge() throws {
        let html = try UsageReportHTMLRenderer.render(UsageReportSnapshot(days: []))
        guard let start = html.range(of: "  let days=[]")?.lowerBound,
              let end = html.range(of: "  const providerDays", range: start..<html.endIndex)?.lowerBound,
              let context = JSContext() else { throw TestDatabaseError.sqlite("Report derivation unavailable") }
        context.evaluateScript("""
            const FIELDS=['input','output','cacheRead','cacheWrite','cacheWrite1h','cost','unpricedTokens','total'];
            const COST_FIELDS=[],ORDER=['piAgent'];
            const zero=keys=>Object.fromEntries(keys.map(k=>[k,0]));
            const addInto=(target,row,keys)=>{for(const key of keys)target[key]+=row?.[key]??0;return target;};
            const sourceId=row=>row.source;
            const periodRange=()=>({from:'2026-09-01',to:'2026-09-01'});
            const toTime=key=>Date.parse(key),fromTime=time=>new Date(time).toISOString().slice(0,10);
            const row=(provider,total)=>({name:'gpt-test',source:'piAgent',upstreamProvider:provider,total,cost:1});
            const BY_DAY=new Map([['2026-09-01',{day:'2026-09-01',recorded:true,sources:[],
                models:[row('openai',10),row('openrouter',20),row('openai',30)]}]]);
            """)
        context.evaluateScript(String(html[start..<end]) + "\nderive();")
        Harness.expect(context.exception == nil, "actual report derivation executes in JavaScriptCore")
        Harness.expectEqual(context.evaluateScript("models.length")?.toInt32(), 2, "JavaScript never merges two upstream providers selling the same model")
        Harness.expectEqual(context.evaluateScript("models.find(m=>m.upstreamProvider==='openai').total")?.toInt32(), 40,
                            "JavaScript still merges matching provider/model rows over a period")
    }
}
