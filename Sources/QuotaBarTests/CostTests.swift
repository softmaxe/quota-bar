import QuotaBarCore
import Combine
import Foundation
import SQLite3

/// Cost-layer checks. The scan tests build synthetic transcripts in a temp directory and drive
/// the real scanner through `CostService`, with pricing pinned so nothing touches the network.
enum CostTests {
    static func run() async {
        Self.iso8601Parsing()
        Self.pricingLookup()
        Self.normalization()
        Self.modelBreakdownRanking()
        Self.fastBreakdownSeparation()
        Self.longContextTiering()
        Self.overlayParsing()
        Self.catalogRefreshBackoff()
        Self.legacyReadOnlyCache()
        Self.logFileScanning()
        do {
            try CostDatabaseLocationTests.run()
            try await CostDatabaseLocationTests.runSchemaMigration()
        } catch {
            Harness.expect(false, "cost database migration tests failed: \(error)")
        }
        await Self.scanning()
        await Self.deletedSessionsRetainUsage()
        await Self.replacedCodexSessionIsReparsed()
        await Self.openCodeScanning()
        await Self.openCodeFastUsageIsSeparate()
        await Self.piAgentScanning()
        await Self.pricingEditsApplyForward()
    }

    // MARK: - Pricing

    private static func replacedCodexSessionIsReparsed() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let file = root.appendingPathComponent("sessions/rollout-test-\(UUID().uuidString).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let context = #"{"type":"turn_context","payload":{"model":"replacement-model"}}"#
            let padding = #"{"type":"response_item","padding":"\#(String(repeating: "x", count: 70_000))"}"#
            func transcript(_ tokens: Int) -> String {
                let usage = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(tokens),"output_tokens":0}}}}"#
                return [context, padding, usage].joined(separator: "\n") + "\n"
            }
            try transcript(100).write(to: file, atomically: true, encoding: .utf8)
            let originalInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
            let service = CostService(
                databaseURL: root.appendingPathComponent("usage.sqlite"),
                env: ["CODEX_HOME": root.path, "OPENCODE_DATA_HOME": root.path, "PI_CODING_AGENT_DIR": root.path],
                pricingOverlay: PricingOverlay(userOverrides: ["replacement-model": ModelPricing(input: 1, output: 2)])
            )
            Harness.expectEqual(await service.refresh(.codex)?.windowTokens, 100, "replacement fixture is scanned")
            try transcript(200).write(to: file, atomically: true, encoding: .utf8)
            let replacementInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
            Harness.expect(originalInode != replacementInode, "atomic replacement changes the fixture inode")
            Harness.expectEqual(await service.refresh(.codex)?.windowTokens, 200,
                                "same-path replacement reparses changed usage beyond an unchanged 64KB prefix")
        } catch {
            Harness.expect(false, "replacement fixture failed: \(error)")
        }
    }

    private static func deletedSessionsRetainUsage() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let home = root.appendingPathComponent("codex")
            let name = "rollout-2026-09-05T10-00-00-\(UUID().uuidString.lowercased()).jsonl"
            let file = home.appendingPathComponent("sessions/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let lines = [
                #"{"type":"turn_context","payload":{"model":"retention-model"}}"#,
                #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#,
            ].joined(separator: "\n") + "\n"
            try lines.write(to: file, atomically: true, encoding: .utf8)
            let database = root.appendingPathComponent("usage.sqlite")
            let env = ["CODEX_HOME": home.path, "XDG_DATA_HOME": root.path, "PI_CODING_AGENT_DIR": root.path]
            let overlay = PricingOverlay(userOverrides: ["retention-model": ModelPricing(input: 1, output: 2)])
            let first = await CostService(databaseURL: database, env: env, pricingOverlay: overlay).refresh(.codex)
            Harness.expectEqual(first?.windowTokens, 120, "retention fixture is scanned")
            let archive = home.appendingPathComponent("archived_sessions/\(name)")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: archive)
            let changedPrices = PricingOverlay(userOverrides: ["retention-model": ModelPricing(input: 100, output: 200)])
            let moved = await CostService(databaseURL: database, env: env, pricingOverlay: changedPrices).refresh(.codex)
            Harness.expectEqual(moved?.windowTokens, 120, "archiving a Codex session does not double count")
            Harness.expectClose(moved?.windowCostUSD, 0.00014, "archiving retains the original price")
            try FileManager.default.copyItem(at: archive, to: file)
            let copied = await CostService(databaseURL: database, env: env, pricingOverlay: changedPrices).refresh(.codex)
            Harness.expectEqual(copied?.windowTokens, 120, "simultaneous archive copies are counted once")
            Harness.expectClose(copied?.windowCostUSD, 0.00014, "a copied session retains the original price")
            try FileManager.default.removeItem(at: home.appendingPathComponent("sessions"))
            try FileManager.default.removeItem(at: home.appendingPathComponent("archived_sessions"))
            let restarted = CostService(databaseURL: database, env: env, pricingOverlay: changedPrices)
            let retained = await restarted.refresh(.codex)
            Harness.expectEqual(retained?.windowTokens, 120, "deleted sessions retain tokens after restart")
            Harness.expectClose(retained?.windowCostUSD, 0.00014, "deleted sessions retain their frozen cost")
            Harness.expectEqual(await restarted.knownModelUsage(provider: .codex),
                                [ModelUsageTotal(model: "retention-model", tokens: 120)],
                                "deleted sessions remain in model usage")
            Harness.expectEqual(retained?.days.first?.dayKey, DayKey.make(from: ISO8601.parse(timestamp)!),
                                "retained usage keeps its original day")
            Harness.expectEqual(retained?.days.first?.rankedModels.first?.key.source, .codex,
                                "retained usage keeps its harness")

            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.write(to: file, atomically: true, encoding: .utf8)
            let restored = await restarted.refresh(.codex)
            Harness.expectEqual(restored?.windowTokens, 120, "restoring a deleted session does not duplicate usage")
            Harness.expectClose(restored?.windowCostUSD, 0.00014, "restoring a session keeps its frozen price")
            if let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd()
                let turn = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#
                try handle.write(contentsOf: Data((turn + "\n").utf8))
                try handle.close()
            }
            let appended = await restarted.refresh(.codex)
            Harness.expectEqual(appended?.windowTokens, 240, "restored sessions continue incremental scanning")
            Harness.expectClose(appended?.windowCostUSD, 0.01414, "only appended usage receives the new price")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.write(to: archive, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: file)
            let olderArchive = await restarted.refresh(.codex)
            Harness.expectEqual(olderArchive?.windowTokens, 240, "deleting a live session preserves usage beyond an older archive copy")
            Harness.expectClose(olderArchive?.windowCostUSD, 0.01414, "an older archive cannot replace recorded costs")

            let claudeHome = root.appendingPathComponent("claude")
            let claudeFile = claudeHome.appendingPathComponent("projects/demo/session.jsonl")
            try FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let claudeLine = #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"retained-request","message":{"id":"retained-message","model":"retention-model","usage":{"input_tokens":100,"output_tokens":20},"content":"PRIVATE_TRANSCRIPT_SENTINEL"}}"# + "\n"
            try claudeLine.write(to: claudeFile, atomically: true, encoding: .utf8)
            let claudeEnv = ["CLAUDE_CONFIG_DIR": claudeHome.path]
            let claude = await CostService(databaseURL: database, env: claudeEnv, pricingOverlay: overlay).refresh(.claude)
            Harness.expectEqual(claude?.windowTokens, 120, "Claude retention fixture is scanned")
            try FileManager.default.removeItem(at: claudeHome)
            let claudeRetained = await CostService(databaseURL: database, env: claudeEnv, pricingOverlay: changedPrices).refresh(.claude)
            Harness.expectEqual(claudeRetained?.windowTokens, 120, "Claude usage survives deleting its session directory and restart")
            Harness.expectClose(claudeRetained?.windowCostUSD, 0.00014, "deleted Claude usage keeps its price")
            Harness.expectEqual(claudeRetained?.days.first?.rankedModels.first?.key.source, .claude,
                                "deleted Claude usage keeps its harness")
            for suffix in ["", "-wal"] {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: database.path + suffix)) {
                    Harness.expect(data.range(of: Data("PRIVATE_TRANSCRIPT_SENTINEL".utf8)) == nil,
                                   "usage storage discards conversation content")
                }
            }

            // A scanner-version marker from an older release must not erase durable history.
            var db: OpaquePointer?
            if sqlite3_open(database.path, &db) == SQLITE_OK {
                sqlite3_exec(db, "PRAGMA user_version = 6", nil, nil, nil)
            }
            sqlite3_close(db)
            let upgraded = await CostService(databaseURL: database, env: claudeEnv, pricingOverlay: changedPrices).refresh(.claude)
            Harness.expectEqual(upgraded?.windowTokens, 120, "scanner version changes preserve deleted-source history")
            Harness.expectClose(upgraded?.windowCostUSD, 0.00014, "scanner version changes preserve frozen prices")
        } catch {
            Harness.expect(false, "session retention fixture failed: \(error)")
        }
    }

    private static func iso8601Parsing() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func reference(_ raw: String) -> Date? {
            fractional.date(from: raw) ?? plain.date(from: raw)
        }

        let samples = [
            "1970-01-01T00:00:00Z",
            "2000-02-29T23:59:59.1Z",
            "2026-09-04T12:34:56.123Z",
            "2026-09-04T12:34:56.123456Z",
            "2026-09-04T12:34:56.123456789Z",
            "2026-09-04T20:34:56+08:00",
            "2026-09-04T05:04:56-07:30",
        ]
        for raw in samples {
            let expected = reference(raw)?.timeIntervalSince1970
            let actual = ISO8601.parse(raw)?.timeIntervalSince1970
            Harness.expectClose(actual, expected ?? .nan, "ISO8601 parser matches Foundation for \(raw)", tolerance: 1e-6)
        }

        for fractionDigits in 1...9 {
            let fraction = String(repeating: "7", count: fractionDigits)
            let raw = "2024-02-29T23:59:58.\(fraction)Z"
            let expected = reference(raw)?.timeIntervalSince1970
            let actual = ISO8601.parse(raw)?.timeIntervalSince1970
            Harness.expectClose(actual, expected ?? .nan, "ISO8601 parser accepts \(fractionDigits) fraction digits", tolerance: 1e-6)
        }
        let fallbackSamples = [
            "",
            "1900-02-29T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-01-01T24:00:00Z",
            "2026-09-04T12:34:56z",
            "2026-09-04T20:34:56+0800",
            "2026-09-04 12:34:56Z",
            "2026-09-04T12:34:56,123Z",
            "2026-09-04T12:34:56",
            "2026-09-04T12:34:60Z",
            "2026-09-04T12:34:56+14:00",
            "2026-09-04T12:34:56+24:00",
            "２０２６-09-04T12:34:56Z",
            "2026-09-04T12:34:56Z trailing",
        ]
        for raw in fallbackSamples {
            Harness.expectEqual(ISO8601.parse(raw), reference(raw), "ISO8601 fallback parity for \(raw)")
        }
    }

    private static func pricingLookup() {
        // CodexBar's table predates these two; they are the reason the built-in table was extended.
        for model in ["claude-opus-5", "claude-sonnet-5"] {
            Harness.expect(
                CostPricing.pricing(for: model, provider: .claude) != nil,
                "\(model) must have a built-in price"
            )
        }

        // 1M input + 1M output on Opus 5 at $5/$25 per million.
        let cost = CostPricing.cost(
            totals: TokenTotals(input: 1_000_000, output: 1_000_000),
            model: "claude-opus-5",
            provider: .claude,
            longContext: false
        )
        Harness.expectEqual(cost, 30.0, "opus-5 cost for 1M in + 1M out")

        // Cache read is a tenth of input; cache write is 1.25x.
        let cacheCost = CostPricing.cost(
            totals: TokenTotals(cacheWrite: 1_000_000, cacheRead: 1_000_000),
            model: "claude-opus-5",
            provider: .claude,
            longContext: false
        )
        Harness.expectEqual(cacheCost, 6.75, "opus-5 cache cost for 1M write + 1M read")

        let codexMini = CostPricing.pricing(for: "codex-mini-latest", provider: .codex)
        Harness.expectClose(codexMini?.input, 1.5, "codex-mini-latest input rate")
        Harness.expectClose(codexMini?.output, 6, "codex-mini-latest output rate")
        Harness.expectClose(codexMini?.cacheRead, 0.375, "codex-mini-latest cached input rate")
        Harness.expect(codexMini?.cacheWrite == nil, "codex-mini-latest has no separate cache-write rate")
        Harness.expect(codexMini?.thresholdTokens == nil, "codex-mini-latest has no long-context tier")

        let fastExpected: [String: ModelPricing] = [
            "gpt-5.6-sol": ModelPricing(
                input: 8, output: 40, cacheWrite: 10, cacheRead: 0.8,
                thresholdTokens: 272_000,
                inputAbove: 16, outputAbove: 60, cacheWriteAbove: 20, cacheReadAbove: 1.6
            ),
            "gpt-5.6-terra": ModelPricing(
                input: 4, output: 24, cacheWrite: 5, cacheRead: 0.4,
                thresholdTokens: 272_000,
                inputAbove: 8, outputAbove: 36, cacheWriteAbove: 10, cacheReadAbove: 0.8
            ),
            "gpt-5.6-luna": ModelPricing(
                input: 0.4, output: 2.4, cacheWrite: 0.5, cacheRead: 0.04,
                thresholdTokens: 272_000,
                inputAbove: 0.8, outputAbove: 3.6, cacheWriteAbove: 1, cacheReadAbove: 0.08
            ),
            "gpt-5.3-codex": ModelPricing(input: 3.5, output: 28, cacheRead: 0.35),
        ]
        for (model, expected) in fastExpected {
            Harness.expectEqual(
                CostPricing.pricing(
                    for: model,
                    provider: .codex,
                    codexServiceTier: .fast
                ),
                expected,
                "\(model) Fast rates match the built-in table"
            )
        }
        for model in ["gpt-5.6-cyber", "codex-mini-latest", "unknown-fast-model"] {
            Harness.expect(
                CostPricing.pricing(
                    for: model,
                    provider: .codex,
                    overlay: PricingOverlay(userOverrides: [model: ModelPricing(input: 99, output: 99)]),
                    codexServiceTier: .fast
                ) == nil,
                "\(model) has no Fast price"
            )
        }

        let haiku = CostPricing.pricing(for: "claude-3-5-haiku-20241022", provider: .claude)
        Harness.expectClose(haiku?.input, 0.8, "claude-3-5-haiku input rate")
        Harness.expectClose(haiku?.output, 4, "claude-3-5-haiku output rate")
        Harness.expectClose(haiku?.cacheWrite, 1, "claude-3-5-haiku five-minute cache-write rate")
        Harness.expectClose(haiku?.cacheRead, 0.08, "claude-3-5-haiku cache-read rate")
        Harness.expectClose(
            haiku?.cacheWrite1hRate(longContext: false),
            1.6,
            "claude-3-5-haiku one-hour cache-write rate is derived"
        )

        // The 5.1 pair is the one Anthropic family that breaks the 0.1x cache-read ratio, so
        // its read rate is worth pinning rather than left to look like a typo.
        let fable = CostPricing.pricing(for: "claude-fable-5-1-20260101", provider: .claude)
        Harness.expectClose(fable?.input, 10, "claude-fable-5-1 input rate")
        Harness.expectClose(fable?.output, 50, "claude-fable-5-1 output rate")
        Harness.expectClose(fable?.cacheWrite, 12.5, "claude-fable-5-1 five-minute cache-write rate")
        Harness.expectClose(fable?.cacheRead, 0.25, "claude-fable-5-1 cache-read rate is 0.025x input")
        Harness.expectClose(
            fable?.cacheWrite1hRate(longContext: false),
            20,
            "claude-fable-5-1 one-hour cache-write rate is derived"
        )
        Harness.expectClose(
            CostPricing.pricing(for: "claude-mythos-5-1", provider: .claude)?.cacheRead,
            0.25,
            "claude-mythos-5-1 shares the 5.1 cache-read rate"
        )
        Harness.expectClose(
            CostPricing.pricing(for: "claude-fable-5", provider: .claude)?.cacheRead,
            1,
            "claude-fable-5 keeps the standard 0.1x cache-read rate"
        )

        // An unknown model must return nil rather than silently costing zero.
        Harness.expect(
            CostPricing.cost(
                totals: TokenTotals(input: 1_000_000),
                model: "some-model-nobody-priced",
                provider: .claude,
                longContext: false
            ) == nil,
            "unknown models must not be priced"
        )
    }

    private static func normalization() {
        Harness.expectEqual(
            CostPricing.normalizeClaudeModel("claude-haiku-4-5-20251001"),
            "claude-haiku-4-5",
            "claude date suffix stripped"
        )
        Harness.expectEqual(
            CostPricing.normalizeClaudeModel("anthropic.claude-opus-4-6-v1:0"),
            "claude-opus-4-6",
            "bedrock prefix and version suffix stripped"
        )
        Harness.expectEqual(
            CostPricing.normalizeClaudeModel("anthropic.claude-3-5-haiku-20241022-v1:0"),
            "claude-3-5-haiku",
            "Haiku 3.5 Bedrock id normalized"
        )
        Harness.expectEqual(
            CostPricing.normalizeClaudeModel("claude-3-5-haiku@20241022"),
            "claude-3-5-haiku",
            "Haiku 3.5 Vertex id normalized"
        )
        Harness.expectEqual(
            CostPricing.normalizeClaudeModel("anthropic.claude-fable-5-1-v1:0"),
            "claude-fable-5-1",
            "a point-release id keeps its minor version"
        )
        Harness.expectEqual(
            CostPricing.normalizeCodexModel("openai/gpt-5.1-2026-01-01"),
            "gpt-5.1",
            "codex vendor prefix and dated suffix stripped"
        )
        Harness.expectEqual(CostPricing.normalizeCodexModel("gpt-5.6"), "gpt-5.6-sol", "sol alias applied")
    }

    private static func modelBreakdownRanking() {
        let day = CostDay(
            dayKey: "2026-09-02",
            byModel: [
                ModelUsageKey(source: .codex, model: "token-heavy"): ModelDayUsage(
                    tokens: TokenTotals(input: 200),
                    costUSD: 1
                ),
                ModelUsageKey(source: .codex, model: "cost-heavy"): ModelDayUsage(
                    tokens: TokenTotals(input: 100),
                    costUSD: 2
                ),
                ModelUsageKey(source: .codex, model: "unpriced"): ModelDayUsage(
                    tokens: TokenTotals(input: 300),
                    costUSD: nil
                ),
            ],
            costUSD: 3,
            unpricedTokens: 300
        )

        Harness.expectEqual(
            day.rankedModels(by: .tokens).map(\.model),
            ["unpriced", "token-heavy", "cost-heavy"],
            "token labels rank the daily breakdown by tokens"
        )
        Harness.expectEqual(
            day.rankedModels(by: .cost).map(\.model),
            ["cost-heavy", "token-heavy", "unpriced"],
            "cost labels rank the daily breakdown by cost"
        )
    }

    private static func fastBreakdownSeparation() {
        let day = CostDay(
            dayKey: "2026-09-04",
            byModel: [
                ModelUsageKey(source: .codex, model: "gpt-5.6-sol", isFast: true): ModelDayUsage(
                    tokens: TokenTotals(input: 100),
                    costUSD: 1
                ),
                ModelUsageKey(source: .openCode, model: "gpt-5.6-luna", isFast: true): ModelDayUsage(
                    tokens: TokenTotals(input: 200),
                    costUSD: 2
                ),
                ModelUsageKey(source: .piAgent, model: "gpt-5.6-terra"): ModelDayUsage(
                    tokens: TokenTotals(input: 50),
                    costUSD: 0.5
                ),
            ],
            costUSD: 3.5,
            unpricedTokens: 0
        )

        let ranked = day.rankedModels(by: .tokens)
        Harness.expectEqual(ranked.count, 3, "Fast usage stays split by source and model")
        Harness.expectEqual(ranked[0].key.source, .openCode, "OpenCode Fast keeps its source")
        Harness.expectEqual(ranked[0].model, "gpt-5.6-luna", "OpenCode Fast keeps its model")
        Harness.expectEqual(ranked[1].key.source, .codex, "Codex Fast keeps its source")
        Harness.expectEqual(ranked[1].model, "gpt-5.6-sol", "Codex Fast keeps its model")
        Harness.expectEqual(ranked[2].key.source, .piAgent, "Pi remains a Standard source/model row")
    }

    private static func longContextTiering() {
        // The gpt-5.6 family charges its long-context rates only above 272k tokens in one request.
        let below = TokenTotals(input: 100_000)
        let above = TokenTotals(input: 300_000)
        Harness.expect(
            !CostPricing.isLongContext(totals: below, model: "gpt-5.6-sol", provider: .codex),
            "100k tokens stays at the base tier"
        )
        Harness.expect(
            CostPricing.isLongContext(totals: above, model: "gpt-5.6-sol", provider: .codex),
            "300k tokens crosses into the long-context tier"
        )
        for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            Harness.expect(
                !CostPricing.isLongContext(
                    totals: TokenTotals(input: 272_000),
                    model: model,
                    provider: .codex
                ),
                "\(model) stays at the base tier at exactly 272k tokens"
            )
            Harness.expect(
                CostPricing.isLongContext(
                    totals: TokenTotals(input: 272_001),
                    model: model,
                    provider: .codex
                ),
                "\(model) crosses into the long-context tier above 272k tokens"
            )
        }
        let baseCost = CostPricing.cost(
            totals: TokenTotals(input: 1_000_000),
            model: "gpt-5.6-sol",
            provider: .codex,
            longContext: false
        )
        let longCost = CostPricing.cost(
            totals: TokenTotals(input: 1_000_000),
            model: "gpt-5.6-sol",
            provider: .codex,
            longContext: true
        )
        Harness.expectEqual(baseCost, 4.0, "sol base input rate")
        Harness.expectEqual(longCost, 8.0, "sol long-context input rate")
    }

    private static func overlayParsing() {
        let overrides = PricingOverlayStore.parseUserOverrides(Data("""
        { "my-model": { "input": 1, "output": 2, "cacheRead": 0.1 } }
        """.utf8))
        Harness.expectEqual(overrides["my-model"]?.input, 1, "user override input rate")

        // models.dev publishes USD per million, keyed provider -> models.
        let catalog = PricingOverlayStore.parseCatalog(Data("""
        {
          "providers": {
            "anthropic": {
              "models": {
                "claude-test-1": {
                  "cost": { "input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75 }
                }
              }
            },
            "openai": {
              "models": { "gpt-test-1": { "cost": { "input": 1, "output": 4 } } }
            }
          }
        }
        """.utf8))
        Harness.expectEqual(catalog?["claude-test-1"]?.output, 15, "models.dev output rate")
        Harness.expectEqual(catalog?["gpt-test-1"]?.input, 1, "models.dev second provider parsed")

        // A user override must win over the catalog for the same model.
        let overlay = PricingOverlay(
            userOverrides: ["claude-opus-5": ModelPricing(input: 99, output: 99)],
            modelsDev: ["claude-opus-5": ModelPricing(input: 1, output: 1)]
        )
        Harness.expectEqual(
            CostPricing.pricing(for: "claude-opus-5", provider: .claude, overlay: overlay)?.input,
            99,
            "user override beats the models.dev catalog"
        )
    }

    // MARK: - models.dev refresh

    /// The pricing pane used to wait on this refresh, and a host that cannot reach models.dev
    /// paid the request timeout on every open because a failure writes no cache and so never
    /// stops looking stale. The backoff is what turns that into one attempt an hour.
    private static func catalogRefreshBackoff() {
        let hour: TimeInterval = 60 * 60

        Harness.expect(
            PricingCatalogRefreshPolicy.shouldRefresh(catalogAge: nil, lastAttemptAge: nil),
            "a catalog that was never fetched is worth fetching"
        )
        Harness.expect(
            !PricingCatalogRefreshPolicy.shouldRefresh(catalogAge: 12 * hour, lastAttemptAge: nil),
            "a catalog inside its TTL is left alone"
        )
        Harness.expect(
            PricingCatalogRefreshPolicy.shouldRefresh(catalogAge: 25 * hour, lastAttemptAge: 2 * hour),
            "a catalog past its TTL refreshes once the backoff has run out"
        )
        Harness.expect(
            PricingCatalogRefreshPolicy.shouldRefresh(catalogAge: nil, lastAttemptAge: 2 * hour),
            "a failure an hour old is retried"
        )
        // A stale catalog still in backoff keeps serving its prices rather than blocking on a
        // fetch; that is the whole point of keeping the old cache on failure.
        Harness.expect(
            !PricingCatalogRefreshPolicy.shouldRefresh(catalogAge: 30 * hour, lastAttemptAge: 5 * 60),
            "a stale catalog waits out the backoff instead of retrying on every call"
        )
    }

    // MARK: - Scanning

    private static func legacyReadOnlyCache() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-legacy-cache-\(ProcessInfo.processInfo.processIdentifier).sqlite")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            Harness.expect(false, "legacy cache fixture opens")
            return
        }
        sqlite3_exec(db, """
            CREATE TABLE codex_day (
                path TEXT, day TEXT, model TEXT, long_context INTEGER,
                input INTEGER, output INTEGER, cache_write INTEGER, cache_read INTEGER
            );
            INSERT INTO codex_day VALUES ('log', '2026-08-31', 'gpt-5.6-luna', 0, 7, 0, 0, 0);
            """, nil, nil, nil)
        sqlite3_close(db)
        let usage = CostUsageReader.knownModelUsage(provider: .codex, databaseURL: url)
        Harness.expectEqual(usage, [ModelUsageTotal(model: "gpt-5.6-luna", tokens: 7)], "old read-only cache needs no OpenCode table")
    }

    private static func logFileScanning() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-line-reader-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func topLevelType(_ raw: String) -> JSONLogClassifier.TopLevelType? {
            Data(raw.utf8).withUnsafeBytes { JSONLogClassifier.topLevelType(in: $0) }
        }
        func payloadType(_ raw: String) -> JSONLogClassifier.PayloadType? {
            Data(raw.utf8).withUnsafeBytes { JSONLogClassifier.payloadType(in: $0) }
        }
        let longPrefix = String(repeating: "x", count: 5_000)
        Harness.expectEqual(
            topLevelType(#"{"padding":"\#(longPrefix)","type":"assistant"}"#),
            .assistant,
            "JSON classifier finds a type after a long preceding value"
        )
        let reordered = #"{"payload":{"nested":[{"type":"decoy"}],"type":"token_count"},"type":"event_msg"}"#
        Harness.expectEqual(topLevelType(reordered), .eventMessage, "JSON classifier tolerates top-level key reordering")
        Harness.expectEqual(payloadType(reordered), .tokenCount, "JSON classifier reads the payload object type")
        let fakeTopLevel = #"{"message":"escaped \"type\":\"assistant\"","type":"user"}"#
        Harness.expectEqual(topLevelType(fakeTopLevel), .other, "a marker inside a string cannot classify a record")
        let fakePayload = #"{"type":"event_msg","payload":{"note":"\"type\":\"token_count\"","type":"agent_message"}}"#
        Harness.expectEqual(payloadType(fakePayload), .other, "a payload marker inside a string is ignored")
        Harness.expectEqual(
            topLevelType(#"{"t\u0079pe":"assistant"}"#),
            .indeterminate,
            "an escaped top-level key falls back to full JSON parsing"
        )
        Harness.expectEqual(
            topLevelType(#"{"type":"assist\u0061nt"}"#),
            .indeterminate,
            "an escaped top-level value falls back to full JSON parsing"
        )
        Harness.expectEqual(
            payloadType(#"{"type":"event_msg","paylo\u0061d":{"type":"token_count"}}"#),
            .indeterminate,
            "an escaped payload key falls back to full JSON parsing"
        )
        Harness.expectEqual(
            payloadType(#"{"type":"event_msg","payload":{"type":"token_\u0063ount"}}"#),
            .indeterminate,
            "an escaped payload value falls back to full JSON parsing"
        )

        let bounded = root.appendingPathComponent("bounded.jsonl")
        try? "first\nsecond\n".write(to: bounded, atomically: true, encoding: .utf8)
        var boundedLines: [String] = []
        let boundedOffset = try? LogFileScanner.readLines(of: bounded, from: 0, upTo: 6) { line in
            boundedLines.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(boundedLines, ["first"], "line reader stops exactly at its byte limit")
        Harness.expectEqual(boundedOffset, 6, "bounded line reader returns the last complete offset")

        var midLineLines: [String] = []
        let midLineOffset = try? LogFileScanner.readLines(of: bounded, from: 0, upTo: 8) { line in
            midLineLines.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(midLineLines, ["first"], "a limit inside a line does not expose that line")
        Harness.expectEqual(midLineOffset, 6, "a mid-line limit keeps the preceding complete offset")

        var beforeStartLines: [String] = []
        let beforeStartOffset = try? LogFileScanner.readLines(of: bounded, from: 6, upTo: 5) { line in
            beforeStartLines.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(beforeStartLines, [], "a limit before the start performs no callbacks")
        Harness.expectEqual(beforeStartOffset, 6, "a limit before the start preserves the start offset")

        let emptyLines = root.appendingPathComponent("empty-lines.jsonl")
        try? "\nvalue\n".write(to: emptyLines, atomically: true, encoding: .utf8)
        var nonempty: [String] = []
        let emptyLinesOffset = try? LogFileScanner.readLines(of: emptyLines, from: 0) { line in
            nonempty.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(nonempty, ["value"], "empty lines advance without invoking the callback")
        Harness.expectEqual(emptyLinesOffset, 7, "empty lines still contribute to the absolute offset")

        let partial = root.appendingPathComponent("partial.jsonl")
        try? "one\ntwo".write(to: partial, atomically: true, encoding: .utf8)
        var firstPass: [String] = []
        let firstOffset = try? LogFileScanner.readLines(of: partial, from: 0) { line in
            firstPass.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(firstPass, ["one"], "line reader defers an incomplete trailing line")
        Harness.expectEqual(firstOffset, 4, "partial line is excluded from the returned offset")

        if let handle = try? FileHandle(forWritingTo: partial) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n".utf8))
            try? handle.close()
        }
        var resumed: [String] = []
        let resumedOffset = try? LogFileScanner.readLines(of: partial, from: Int64(firstOffset ?? 0)) { line in
            resumed.append(String(decoding: line, as: UTF8.self))
        }
        Harness.expectEqual(resumed, ["two"], "line reader resumes at the deferred trailing line")
        Harness.expectEqual(resumedOffset, 8, "resumed line reader advances through the appended newline")

        let spanning = root.appendingPathComponent("spanning.jsonl")
        let largeLine = String(repeating: "x", count: (1 << 20) + 17)
        try? "\(largeLine)\ny\n".write(to: spanning, atomically: true, encoding: .utf8)
        var lengths: [Int] = []
        let spanningOffset = try? LogFileScanner.readLines(of: spanning, from: 0) { line in
            lengths.append(line.count)
        }
        Harness.expectEqual(lengths, [largeLine.utf8.count, 1], "line reader preserves a line spanning chunks")
        Harness.expectEqual(
            spanningOffset,
            Int64(largeLine.utf8.count + 3),
            "line reader counts bytes across chunk boundaries"
        )
    }

    private static func openCodeScanning() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-opencode-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let openCodeHome = root.appendingPathComponent("opencode")
        try? FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: openCodeHome, withIntermediateDirectories: true)
        try? #"{"tokens":{"account_id":"account-a"}}"#.write(
            to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        let source = openCodeHome.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        guard sqlite3_open(source.path, &db) == SQLITE_OK, let db else {
            Harness.expect(false, "OpenCode fixture database opens")
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, data TEXT NOT NULL)", nil, nil, nil)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func insert(_ id: String, provider: String = "openai", model: String = "gpt-5.6-luna") {
            let message = #"{"time":{"created":\#(now)},"providerID":"\#(provider)","modelID":"\#(model)"}"#
            let part = #"{"type":"step-finish","tokens":{"input":10,"output":20,"reasoning":30,"cache":{"read":40,"write":50}}}"#
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message (id, data) VALUES (?, ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, "message-\(id)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, message, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            sqlite3_prepare_v2(db, "INSERT INTO part (id, message_id, data) VALUES (?, ?, ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, "message-\(id)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, part, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        insert("part-1")
        insert("third-party", provider: "openrouter")

        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: ["CODEX_HOME": codexHome.path, "OPENCODE_DATA_HOME": openCodeHome.path],
            pricingOverlay: PricingOverlay()
        )
        let first = await service.refresh(.codex)
        Harness.expectEqual(first?.windowTokens, 150, "OpenCode maps output reasoning and cache buckets")
        Harness.expectEqual(first?.days.first?.tokens.output, 50, "OpenCode reasoning is output")
        Harness.expectEqual(first?.days.first?.tokens.cacheRead, 40, "OpenCode cache reads are preserved")
        Harness.expectEqual(first?.days.first?.tokens.cacheWrite, 50, "OpenCode cache writes are preserved")
        Harness.expect(
            first?.days.first?.rankedModels.first?.key.source == .openCode,
            "OpenCode usage keeps its source in the day breakdown"
        )
        Harness.expectEqual(await service.currentOpenCodeScanStatus(), .idle, "matching OAuth is quiet")

        let repeated = await service.refresh(.codex)
        Harness.expectEqual(repeated?.windowTokens, 150, "OpenCode part IDs dedupe repeated scans")

        sqlite3_exec(
            db,
            "UPDATE part SET data = '{\"type\":\"step-finish\",\"tokens\":{\"input\":10,\"output\":120,\"reasoning\":30,\"cache\":{\"read\":40,\"write\":50}}}' WHERE id = 'part-1'",
            nil,
            nil,
            nil
        )
        let completed = await service.refresh(.codex)
        Harness.expectEqual(completed?.windowTokens, 250, "a growing OpenCode part updates its frozen usage")
        let completedCost = completed?.windowCostUSD
        await service.usePricingOverlay(PricingOverlay(userOverrides: [
            "gpt-5.6-luna": ModelPricing(
                input: 100,
                output: 100,
                cacheWrite: 100,
                cacheRead: 100,
                thresholdTokens: 1,
                inputAbove: 200,
                outputAbove: 200
            ),
        ]))
        let repriced = await service.refresh(.codex)
        Harness.expectClose(repriced?.windowCostUSD, completedCost ?? -1, "an overlay change does not reprice unchanged OpenCode usage")

        try? #"{"openai":{"type":"api","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        insert("part-2")
        let excluded = await service.refresh(.codex)
        Harness.expectEqual(excluded?.windowTokens, 250, "API-key OpenCode rows are excluded")
        Harness.expectEqual(await service.currentOpenCodeScanStatus(), .nonOAuth, "non-OAuth status is exposed")

        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        let frozen = await service.refresh(.codex)
        Harness.expectEqual(frozen?.windowTokens, 250, "excluded OpenCode rows stay excluded")

        try? #"{"openai":null}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        insert("part-3")
        let indeterminate = await service.refresh(.codex)
        Harness.expectEqual(indeterminate?.windowTokens, 250, "indeterminate auth does not classify new rows")
        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        let retried = await service.refresh(.codex)
        Harness.expectEqual(retried?.windowTokens, 400, "unclassified rows retry after auth recovers")

        try? #"{"openai":{"type":"oauth","accountId":"account-b"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        insert("part-4")
        let mismatch = await service.refresh(.codex)
        Harness.expectEqual(mismatch?.windowTokens, 400, "a different OpenAI account is excluded")
        Harness.expectEqual(await service.currentOpenCodeScanStatus(), .accountMismatch, "account mismatch status is exposed")

        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        sqlite3_exec(db, "DELETE FROM part WHERE id = 'part-1'", nil, nil, nil)
        let pruned = await service.refresh(.codex)
        Harness.expectEqual(pruned?.windowTokens, 400, "deleted OpenCode parts retain their usage")

        insert("unknown", model: "future-openai-model")
        let unknown = await service.refresh(.codex)
        Harness.expectEqual(unknown?.windowTokens, 550, "unknown OpenAI models still count tokens")
        Harness.expectEqual(unknown?.hasUnpricedTokens, true, "unknown OpenAI models are unpriced")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let codexLog = codexHome.appendingPathComponent("sessions/rollout-opencode-error.jsonl")
        let codexLines = """
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.6-luna"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0}}}}

        """
        try? codexLines.write(to: codexLog, atomically: true, encoding: .utf8)
        sqlite3_exec(db, "ALTER TABLE message RENAME TO broken_message", nil, nil, nil)
        let sourceFailure = await service.refresh(.codex)
        Harness.expectEqual(sourceFailure?.windowTokens, 560, "OpenCode schema errors retain history while Codex keeps scanning")
        let lunaSources = Set(sourceFailure?.days.first?.rankedModels
            .filter { $0.model == "gpt-5.6-luna" }
            .map { $0.key.source } ?? [])
        Harness.expectEqual(
            lunaSources,
            Set([CostUsageSource.codex, .openCode]),
            "same-model Codex and OpenCode usage remains split by source"
        )
        if case .error = await service.currentOpenCodeScanStatus() {
            Harness.expect(true, "OpenCode schema error status is exposed")
        } else {
            Harness.expect(false, "OpenCode schema error status is exposed")
        }

        try? FileManager.default.removeItem(at: source)
        let removed = await service.refresh(.codex)
        Harness.expectEqual(removed?.windowTokens, 560, "a removed OpenCode database retains its usage")
        Harness.expectEqual(await service.currentOpenCodeScanStatus(), .idle, "a removed OpenCode database is idle")
    }

    private static func piAgentScanning() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-pi-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let agentHome = root.appendingPathComponent("pi-agent")
        let sessions = root.appendingPathComponent("pi-sessions")
        try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessions.appendingPathComponent("project"), withIntermediateDirectories: true)
        try? #"{"tokens":{"account_id":"account-a"}}"#.write(
            to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        try? #"{"openai-codex":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: agentHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let transcript = sessions.appendingPathComponent("project/session.jsonl")
        func message(
            _ id: String,
            model: String = "gpt-5.6-luna",
            input: Int = 10,
            output: Int = 20,
            cacheWrite: Int = 30,
            cacheRead: Int = 40
        ) -> String {
            #"{"type":"message","id":"\#(id)","message":{"role":"assistant","provider":"openai-codex","model":"\#(model)","service_tier":"priority","timestamp":\#(now),"usage":{"input":\#(input),"output":\#(output),"reasoning":999,"cacheWrite":\#(cacheWrite),"cacheRead":\#(cacheRead),"cost":999}}}"#
        }
        func write(_ lines: [String]) {
            try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        }
        write([
            message("one"),
            #"{"type":"message","message":{"id":"ignored","role":"assistant","provider":"other","model":"gpt-5.6-luna","timestamp":\#(now),"usage":{"input":500}}}"#,
        ])

        let overlay = PricingOverlay(userOverrides: [
            "gpt-5.6-luna": ModelPricing(input: 1, output: 2, cacheWrite: 3, cacheRead: 0.5),
        ])
        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: [
                "CODEX_HOME": codexHome.path,
                "PI_CODING_AGENT_DIR": agentHome.path,
                "PI_CODING_AGENT_SESSION_DIR": sessions.path,
                "OPENCODE_DATA_HOME": root.appendingPathComponent("missing-opencode").path,
            ],
            pricingOverlay: overlay
        )

        let first = await service.refresh(.codex)
        Harness.expectEqual(first?.windowTokens, 100, "Pi maps token buckets without adding reasoning twice")
        Harness.expectEqual(first?.days.first?.tokens.input, 10, "Pi input excludes cache reads")
        Harness.expectEqual(first?.days.first?.tokens.output, 20, "Pi output already contains reasoning")
        Harness.expectEqual(first?.days.first?.tokens.cacheWrite, 30, "Pi cache writes are preserved")
        Harness.expectEqual(first?.days.first?.tokens.cacheRead, 40, "Pi cache reads are preserved")
        Harness.expect(
            first?.days.first?.rankedModels.first?.key.source == .piAgent,
            "Pi usage keeps its source in the day breakdown"
        )
        Harness.expect(
            first?.days.first?.rankedModels.allSatisfy { !$0.key.isFast } == true,
            "Pi service-tier metadata is intentionally ignored"
        )
        Harness.expectClose(first?.windowCostUSD, 0.00016, "Pi usage uses local model pricing")
        Harness.expectEqual(await service.currentPiAgentScanStatus(), .idle, "matching Pi OAuth is quiet")

        let forkedTranscript = sessions.appendingPathComponent("project/fork.jsonl")
        try? (message("one") + "\n").write(to: forkedTranscript, atomically: true, encoding: .utf8)
        let repeated = await service.refresh(.codex)
        Harness.expectEqual(repeated?.windowTokens, 100, "Pi message IDs dedupe copied session history")
        try? FileManager.default.removeItem(at: forkedTranscript)

        write([message("one", output: 120), message("two")])
        let grown = await service.refresh(.codex)
        Harness.expectEqual(grown?.windowTokens, 300, "Pi updates growing messages and adds new messages")

        try? #"{"openai-codex":{"type":"api","accountId":"account-a"}}"#.write(
            to: agentHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        write([message("one", output: 120), message("two"), message("excluded")])
        let nonOAuth = await service.refresh(.codex)
        Harness.expectEqual(nonOAuth?.windowTokens, 300, "non-OAuth Pi messages are excluded")
        Harness.expectEqual(await service.currentPiAgentScanStatus(), .nonOAuth, "Pi non-OAuth status is exposed")

        try? #"{"openai-codex":{"type":"oauth","accountId":"account-b"}}"#.write(
            to: agentHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        let mismatch = await service.refresh(.codex)
        Harness.expectEqual(mismatch?.windowTokens, 300, "Pi account mismatch stays excluded")
        Harness.expectEqual(await service.currentPiAgentScanStatus(), .accountMismatch, "Pi account mismatch status is exposed")

        try? #"{"openai-codex":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: agentHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        write([message("two"), message("unknown", model: "future-codex-model")])
        let pruned = await service.refresh(.codex)
        Harness.expectEqual(pruned?.windowTokens, 400, "Pi retains messages missing from the source")
        Harness.expectEqual(pruned?.hasUnpricedTokens, true, "unknown Pi models keep unpriced tokens")

        try? "invalid".write(to: agentHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        write([])
        let authFailure = await service.refresh(.codex)
        Harness.expectEqual(authFailure?.windowTokens, 400, "Pi auth errors retain recorded totals")
        if case .error = await service.currentPiAgentScanStatus() {
            Harness.expect(true, "Pi auth error status is exposed")
        } else {
            Harness.expect(false, "Pi auth error status is exposed")
        }

        try? FileManager.default.removeItem(at: sessions)
        let removed = await service.refresh(.codex)
        Harness.expectEqual(removed?.windowTokens, 400, "a missing Pi sessions directory retains usage")
        Harness.expectEqual(await service.currentPiAgentScanStatus(), .idle, "missing Pi sessions are idle")
    }

    /// A price edit must not rewrite history: what has already been scanned keeps the cost it was
    /// billed at, and the new rate reaches only the turns logged afterwards.
    private static func pricingEditsApplyForward() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-forwardprices-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let logFile = codexHome.appendingPathComponent("sessions/rollout-forward.jsonl")
        try? FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Stamped now, so the day always lands inside the 30-day window the snapshot covers.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        // 200k input stays under luna's 272k long-context threshold, so the base rate applies.
        let turn = """
        {"type":"turn_context","timestamp":"\(now)","payload":{"model":"gpt-5.6-luna"}}
        {"type":"event_msg","timestamp":"\(now)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}

        """
        try? turn.write(to: logFile, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: ["CODEX_HOME": codexHome.path, "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path],
            pricingOverlay: PricingOverlay()
        )

        let append = {
            guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(turn.utf8))
            try? handle.close()
        }

        let before = await service.refresh(.codex)
        Harness.expectClose(before?.windowCostUSD, 0.04, "200k luna tokens at the built-in rate")

        // A turn logged before the edit but not yet scanned still belongs to the old rate.
        append()

        // What the settings pane does on Save: seal what is on disk, then move the rates.
        do {
            try await service.freezeCurrentPrices()
        } catch {
            Harness.expect(false, "freezing prices threw: \(error)")
            return
        }
        await service.usePricingOverlay(PricingOverlay(
            userOverrides: ["gpt-5.6-luna": ModelPricing(input: 5, output: 5)]
        ))

        let sealed = await service.refresh(.codex)
        Harness.expectEqual(sealed?.windowTokens, 400_000, "the pending turn is scanned before the edit")
        Harness.expectClose(sealed?.windowCostUSD, 0.08, "a price edit leaves recorded usage alone")

        append()

        let after = await service.refresh(.codex)
        Harness.expectEqual(after?.windowTokens, 600_000, "the turn logged after the edit is scanned")
        // 0.08 frozen at the old rate plus 200k at the new $5/M rate.
        Harness.expectClose(after?.windowCostUSD, 1.08, "only new usage bills at the new rate")
    }

    private static func scanning() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-costtests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let claudeHome = root.appendingPathComponent("claude")
        let codexFile = codexHome.appendingPathComponent("sessions/2026/08/26/rollout-test.jsonl")
        let claudeFile = claudeHome.appendingPathComponent("projects/demo/session.jsonl")
        for url in [codexFile, claudeFile] {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let day = "2026-08-26T10:00:00.000Z"
        // turn_context names the model; each token_count carries that turn's delta.
        // A real day mixes models: turn_context announces the model for the turns that follow.
        let solTurn = #"{"type":"event_msg","timestamp":"\#(day)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#
        let codexLines = [
            #"{"type":"turn_context","timestamp":"\#(day)","payload":{"model":"gpt-5.6-sol"}}"#,
            solTurn,
            #"{"type":"turn_context","timestamp":"\#(day)","payload":{"model":"gpt-5.6-luna"}}"#,
            solTurn,
        ]
        let claudeLines = [
            #"{"type":"assistant","timestamp":"\#(day)","requestId":"req-1","uuid":"u1","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":200000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            // Same message replayed into the same transcript must be counted once.
            #"{"type":"assistant","timestamp":"\#(day)","requestId":"req-1","uuid":"u2","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":200000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ]
        try? (codexLines.joined(separator: "\n") + "\n").write(to: codexFile, atomically: true, encoding: .utf8)
        try? (claudeLines.joined(separator: "\n") + "\n").write(to: claudeFile, atomically: true, encoding: .utf8)

        let env = ["CODEX_HOME": codexHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path]
        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: env,
            pricingOverlay: PricingOverlay()
        )

        let codex = await service.refresh(.codex)
        // 200k input tokens stays under sol's 272k long-context threshold, so the base rate
        // applies: 200k at $4/M for sol plus 200k at $0.20/M for luna.
        Harness.expectEqual(codex?.windowTokens, 400_000, "codex tokens scanned")
        Harness.expectClose(codex?.windowCostUSD, 0.84, "codex cost across two models")
        Harness.expectEqual(codex?.topModel, "gpt-5.6-sol", "codex top model")

        // The hover breakdown needs each model's own share, ranked by cost.
        let breakdown = codex?.days.first
        Harness.expectEqual(breakdown?.byModel.count, 2, "both models appear in the day breakdown")
        Harness.expectEqual(
            breakdown?.rankedModels.first?.model,
            "gpt-5.6-sol",
            "the costlier model ranks first"
        )
        Harness.expectClose(breakdown?.rankedModels.first?.usage.costUSD, 0.8, "per-model cost for sol")
        Harness.expectClose(breakdown?.rankedModels.last?.usage.costUSD, 0.04, "per-model cost for luna")
        Harness.expect(
            breakdown?.rankedModels.allSatisfy { $0.key.source == .codex } == true,
            "Codex CLI usage keeps its source in the day breakdown"
        )

        let claude = await service.refresh(.claude)
        // The duplicated message must not double the total.
        Harness.expectEqual(claude?.windowTokens, 200_000, "claude dedupes a replayed message")
        Harness.expectClose(claude?.windowCostUSD, 1.0, "claude cost at the opus-5 input rate")

        // Scanning Claude must not evict Codex's rows: each scanner only knows its own roots, so
        // an unscoped prune would wipe the other provider every refresh.
        let codexAfter = await service.refresh(.codex)
        Harness.expectEqual(codexAfter?.windowTokens, 400_000, "codex survives a Claude scan")

        // Appending must add to the totals rather than restate them, and the appended turn must
        // land on the model named by the last turn_context -- which a resumed scan has to recover
        // by rereading the turn_context lines it already skipped past.
        let appended = solTurn + "\n"
        if let handle = try? FileHandle(forWritingTo: codexFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(appended.utf8))
            try? handle.close()
        }
        let codexGrown = await service.refresh(.codex)
        Harness.expectEqual(codexGrown?.windowTokens, 600_000, "appended turns are picked up incrementally")
        Harness.expectClose(
            codexGrown?.days.first?.byModel[
                ModelUsageKey(source: .codex, model: "gpt-5.6-luna")
            ]?.costUSD,
            0.08,
            "a resumed scan attributes the appended turn to the last announced model"
        )
        let modelUsage = await service.knownModelUsage(provider: .codex)
        Harness.expectEqual(modelUsage.first?.model, "gpt-5.6-luna", "pricing models sort by token usage")
        Harness.expectEqual(modelUsage.first?.tokens, 400_000, "pricing model usage carries token totals")

        await Self.claudeStreamingChunksKeepTheFinalOutput(root: root)
        await Self.claudeOneHourCacheWritesCostDouble(root: root)
        await Self.escapedClassifierRecordsAreScanned(root: root)
        await Self.codexSkipsReEmittedTokenCounts(root: root)
        await Self.codexResumeLimitDoesNotPeek(root: root)
        await Self.truncatedCodexLogIsForgotten(root: root)
        await Self.codexCacheBucketsAreCarvedOutOfInput(root: root)
        await Self.codexFastServiceTierPricing(root: root)
    }

    private static func codexFastServiceTierPricing(root: URL) async {
        let home = root.appendingPathComponent("fast-codex")
        let file = home.appendingPathComponent("sessions/rollout-fast.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let priorityLines = [
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try? (priorityLines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("fast-cache.sqlite"),
            env: ["CODEX_HOME": home.path],
            pricingOverlay: PricingOverlay()
        )
        let snapshot = await service.refresh(.codex)
        let modelUsage = await service.knownModelUsage(provider: .codex)

        Harness.expectEqual(snapshot?.windowTokens, 100_000, "Fast usage tokens are scanned")
        Harness.expectEqual(
            modelUsage,
            [ModelUsageTotal(model: "gpt-5.6-sol", tokens: 100_000)],
            "Fast usage stays attributed to the turn context model"
        )
        Harness.expectClose(
            snapshot?.windowCostUSD,
            0.8,
            "priority maps to the Fast short-context rate"
        )
        Harness.expectEqual(
            snapshot?.days.first?.rankedModels.first?.key.isFast,
            true,
            "priority usage is exposed as Fast in the breakdown"
        )

        let appended = priorityLines.last! + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(appended.utf8))
            try? handle.close()
        }
        let resumed = await service.refresh(.codex)
        Harness.expectEqual(resumed?.windowTokens, 200_000, "incremental Fast scanning adds only the new turn")
        Harness.expectClose(resumed?.windowCostUSD, 1.6, "incremental scanning restores the Fast tier")

        let standardTurn = [
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"default"}}}"#,
            priorityLines.last!,
        ].joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(standardTurn.utf8))
            try? handle.close()
        }
        let mixed = await service.refresh(.codex)
        let fastKey = ModelUsageKey(source: .codex, model: "gpt-5.6-sol", isFast: true)
        let standardKey = ModelUsageKey(source: .codex, model: "gpt-5.6-sol")
        Harness.expectEqual(mixed?.windowTokens, 300_000, "Standard and Fast turns both count")
        Harness.expectClose(mixed?.windowCostUSD, 2.0, "Standard and Fast turns keep their own rates")
        Harness.expectEqual(mixed?.days.first?.byModel.count, 2, "Standard and Fast use separate rows")
        Harness.expectEqual(mixed?.days.first?.byModel[fastKey]?.tokens.total, 200_000, "Fast tokens stay separate")
        Harness.expectEqual(mixed?.days.first?.byModel[standardKey]?.tokens.total, 100_000, "Standard tokens stay separate")

        func scanTier(_ rawTier: String?, name: String) async -> CostSnapshot? {
            let tierHome = root.appendingPathComponent("\(name)-codex")
            let tierFile = tierHome.appendingPathComponent("sessions/rollout.jsonl")
            try? FileManager.default.createDirectory(
                at: tierFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let settings: String
            if let rawTier {
                settings = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"\#(rawTier)"}}}"#
            } else {
                settings = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"thread_settings_applied","thread_settings":{}}}"#
            }
            let lines = [settings, priorityLines[1], priorityLines[2]]
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: tierFile, atomically: true, encoding: .utf8)
            let tierService = CostService(
                databaseURL: root.appendingPathComponent("\(name)-cache.sqlite"),
                env: ["CODEX_HOME": tierHome.path],
                pricingOverlay: PricingOverlay()
            )
            return await tierService.refresh(.codex)
        }

        let literalFast = await scanTier("fast", name: "literal-fast")
        Harness.expectEqual(literalFast?.windowTokens, 100_000, "literal fast keeps all token totals")
        Harness.expectClose(literalFast?.windowCostUSD, 0.8, "literal fast maps to the Fast rate")

        let standard = await scanTier("default", name: "default")
        Harness.expectEqual(standard?.windowTokens, 100_000, "default keeps all token totals")
        Harness.expectClose(standard?.windowCostUSD, 0.4, "default stays on the Standard rate")

        let missing = await scanTier(nil, name: "missing")
        Harness.expectClose(missing?.windowCostUSD, 0.4, "a missing service tier stays Standard")
    }

    private static func openCodeFastUsageIsSeparate() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-opencode-fast-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex")
        let openCodeHome = root.appendingPathComponent("opencode")
        try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: openCodeHome, withIntermediateDirectories: true)
        try? #"{"tokens":{"account_id":"account-a"}}"#.write(
            to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        try? #"{"openai":{"type":"oauth","accountId":"account-a"}}"#.write(
            to: openCodeHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )

        var db: OpaquePointer?
        guard sqlite3_open(openCodeHome.appendingPathComponent("opencode.db").path, &db) == SQLITE_OK,
              let db else {
            Harness.expect(false, "OpenCode Fast fixture database opens")
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, data TEXT NOT NULL)", nil, nil, nil)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func insert(table: String, id: String, data: String, messageID: String? = nil) {
            var stmt: OpaquePointer?
            let sql = messageID == nil
                ? "INSERT INTO \(table) (id, data) VALUES (?, ?)"
                : "INSERT INTO \(table) (id, message_id, data) VALUES (?, ?, ?)"
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let messageID {
                sqlite3_bind_text(stmt, 2, messageID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_text(stmt, 2, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        func assistant(_ id: String, created: Int64, metadataTier: String? = nil) {
            insert(
                table: "message",
                id: "message-\(id)",
                data: #"{"time":{"created":\#(created)},"role":"assistant","providerID":"openai","modelID":"gpt-5.6-sol"}"#
            )
            insert(
                table: "part",
                id: "finish-\(id)",
                data: #"{"type":"step-finish","tokens":{"input":100000,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#,
                messageID: "message-\(id)"
            )
            if let metadataTier {
                insert(
                    table: "part",
                    id: "text-\(id)",
                    data: #"{"type":"text","text":"","metadata":{"openai":{"serviceTier":"\#(metadataTier)"}}}"#,
                    messageID: "message-\(id)"
                )
            }
        }

        assistant("standard", created: now)
        assistant("metadata-fast", created: now + 1, metadataTier: "priority")
        insert(
            table: "message",
            id: "fast-toggle",
            data: #"{"time":{"created":\#(now + 2)},"role":"user"}"#
        )
        insert(
            table: "part",
            id: "fast-toggle-text",
            data: #"{"type":"text","text":"Fast mode is now ON.","ignored":true}"#,
            messageID: "fast-toggle"
        )
        assistant("toggle-fast", created: now + 3)
        insert(
            table: "message",
            id: "standard-toggle",
            data: #"{"time":{"created":\#(now + 4)},"role":"user"}"#
        )
        insert(
            table: "part",
            id: "standard-toggle-text",
            data: #"{"type":"text","text":"Fast mode is now OFF.","ignored":true}"#,
            messageID: "standard-toggle"
        )
        assistant("toggle-standard", created: now + 5)

        let service = CostService(
            databaseURL: root.appendingPathComponent("cache.sqlite"),
            env: [
                "CODEX_HOME": codexHome.path,
                "OPENCODE_DATA_HOME": openCodeHome.path,
                "PI_CODING_AGENT_DIR": root.appendingPathComponent("missing-pi").path,
            ],
            pricingOverlay: PricingOverlay()
        )
        let snapshot = await service.refresh(.codex)
        let standardKey = ModelUsageKey(source: .openCode, model: "gpt-5.6-sol")
        let fastKey = ModelUsageKey(source: .openCode, model: "gpt-5.6-sol", isFast: true)
        Harness.expectEqual(snapshot?.windowTokens, 400_000, "OpenCode Standard and Fast tokens both count")
        Harness.expectClose(snapshot?.windowCostUSD, 2.4, "OpenCode Fast usage uses the Fast rate")
        Harness.expectEqual(snapshot?.days.first?.byModel.count, 2, "OpenCode Fast has its own row")
        Harness.expectEqual(snapshot?.days.first?.byModel[standardKey]?.tokens.total, 200_000, "OpenCode Standard tokens stay separate")
        Harness.expectEqual(snapshot?.days.first?.byModel[fastKey]?.tokens.total, 200_000, "OpenCode Fast tokens stay separate")
    }

    /// Claude writes an assistant message several times while it streams. The prompt figures are
    /// final from the first chunk, but output_tokens grows, so the last chunk is the honest one.
    private static func claudeStreamingChunksKeepTheFinalOutput(root: URL) async {
        let projects = root.appendingPathComponent("stream-claude/projects/app")
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session.jsonl")

        func line(output: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-08-26T15:00:00.000Z","requestId":"req-1","message":{"id":"msg-1","model":"stream-model","usage":{"input_tokens":100000,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        }
        // A partial chunk, then the finished reply, then the same message replayed into a fork.
        let lines = [line(output: 40), line(output: 20_000), line(output: 20_000)]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("stream-cache.sqlite"),
            env: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("stream-claude").path],
            pricingOverlay: PricingOverlay(userOverrides: [
                "stream-model": ModelPricing(input: 1, output: 2),
            ])
        )
        let snapshot = await service.refresh(.claude)
        // $0.10 of prompt and $0.04 of reply, counted once: the partial chunk and the replay lose.
        Harness.expectClose(
            snapshot?.windowCostUSD,
            0.14,
            "a streamed message is billed once, at the output count of its final chunk"
        )
        Harness.expectEqual(
            snapshot?.windowTokens,
            120_000,
            "replaying a finished message does not add its tokens again"
        )
    }

    /// Anthropic bills a one-hour cache write at twice the input rate and a five-minute one at
    /// 1.25x, so the two TTLs cannot share the table's single cache-write column.
    private static func claudeOneHourCacheWritesCostDouble(root: URL) async {
        let projects = root.appendingPathComponent("ttl-claude/projects/app")
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session.jsonl")

        func line(_ id: String, fiveMinute: Int, oneHour: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-08-26T14:00:00.000Z","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","model":"ttl-model","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":\#(fiveMinute + oneHour),"cache_creation":{"ephemeral_5m_input_tokens":\#(fiveMinute),"ephemeral_1h_input_tokens":\#(oneHour)},"cache_read_input_tokens":0}}}"#
        }
        let lines = [
            line("a", fiveMinute: 100_000, oneHour: 0),
            line("b", fiveMinute: 0, oneHour: 100_000),
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("ttl-cache.sqlite"),
            env: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("ttl-claude").path],
            pricingOverlay: PricingOverlay(userOverrides: [
                "ttl-model": ModelPricing(input: 10, output: 0, cacheWrite: 12.5, cacheRead: 0),
            ])
        )
        let snapshot = await service.refresh(.claude)
        // 100k at the 12.5 five-minute rate + 100k at 2x the 10 input rate = $3.25.
        Harness.expectClose(
            snapshot?.windowCostUSD,
            3.25,
            "a one-hour cache write costs twice input while a five-minute one uses the table rate"
        )
        Harness.expectEqual(
            snapshot?.windowTokens,
            200_000,
            "the one-hour subset is not counted a second time in the token total"
        )
    }

    /// Codex re-emits a token_count when its rate-limit block refreshes. The replay repeats the
    /// previous last_token_usage while total_token_usage stands still, and must not be counted.
    private static func codexSkipsReEmittedTokenCounts(root: URL) async {
        let home = root.appendingPathComponent("replay-codex")
        let file = home.appendingPathComponent("sessions/2026/08/26/rollout-replay.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        func event(_ time: String, last: Int, total: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(time)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(last),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#
        }
        let context = #"{"type":"turn_context","timestamp":"2026-08-26T13:00:00.000Z","payload":{"model":"replay-model"}}"#
        let lines = [
            context,
            event("2026-08-26T13:00:01.000Z", last: 100_000, total: 100_000),
            event("2026-08-26T13:00:02.000Z", last: 100_000, total: 200_000),
            // Same running total as the line above: a re-emission, not a third turn.
            event("2026-08-26T13:00:03.000Z", last: 100_000, total: 200_000),
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("replay-cache.sqlite")
        let env = ["CODEX_HOME": home.path]
        let overlay = PricingOverlay(userOverrides: [
            "replay-model": ModelPricing(input: 1, output: 1),
        ])
        let snapshot = await CostService(databaseURL: database, env: env, pricingOverlay: overlay)
            .refresh(.codex)
        Harness.expectClose(
            snapshot?.windowCostUSD,
            0.2,
            "a re-emitted token_count is not counted as another turn"
        )

        // The replay is the last line, so a resumed scan has to recognise it across the boundary.
        let appended = event("2026-08-26T13:00:04.000Z", last: 100_000, total: 200_000)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((appended + "\n").utf8))
            try? handle.close()
        }
        let resumed = await CostService(databaseURL: database, env: env, pricingOverlay: overlay)
            .refresh(.codex)
        Harness.expectClose(
            resumed?.windowCostUSD,
            0.2,
            "a resumed scan still recognises a replay of the turn it stopped on"
        )
    }

    private static func escapedClassifierRecordsAreScanned(root: URL) async {
        let codexHome = root.appendingPathComponent("escaped-codex")
        let claudeHome = root.appendingPathComponent("escaped-claude")
        let codexFile = codexHome.appendingPathComponent("sessions/rollout.jsonl")
        let claudeFile = claudeHome.appendingPathComponent("projects/demo/session.jsonl")
        for file in [codexFile, claudeFile] {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let timestamp = "2026-09-04T12:00:00.000Z"
        let codexLines = [
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"escaped-model"}}"#,
            #"{"t\u0079pe":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_\u0063ount","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try? (codexLines.joined(separator: "\n") + "\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        let claudeLine = #"{"t\u0079pe":"assistant","timestamp":"\#(timestamp)","requestId":"escaped-request","message":{"id":"escaped-message","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        try? (claudeLine + "\n").write(to: claudeFile, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("escaped-classifier-cache.sqlite"),
            env: ["CODEX_HOME": codexHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path],
            pricingOverlay: PricingOverlay()
        )
        Harness.expectEqual(
            await service.refresh(.codex)?.windowTokens,
            100,
            "escaped Codex type fields still reach full JSON parsing"
        )
        Harness.expectEqual(
            await service.refresh(.claude)?.windowTokens,
            100,
            "escaped Claude type fields still reach full JSON parsing"
        )
    }

    private static func codexResumeLimitDoesNotPeek(root: URL) async {
        let home = root.appendingPathComponent("bounded-resume-codex")
        let file = home.appendingPathComponent("sessions/rollout.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = "2026-08-26T13:00:00.000Z"
        let context = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"bounded-model"}}"#
        func event(total: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":\#(total)}}}}"#
        }
        try? ([context, event(total: 100)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("bounded-resume-cache.sqlite"),
            env: ["CODEX_HOME": home.path],
            pricingOverlay: PricingOverlay()
        )
        let first = await service.refresh(.codex)
        Harness.expectEqual(first?.windowTokens, 100, "bounded resume fixture scans its first turn")

        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((event(total: 200) + "\n").utf8))
            try? handle.close()
        }
        let resumed = await service.refresh(.codex)
        Harness.expectEqual(
            resumed?.windowTokens,
            200,
            "resume state cannot peek past the saved cursor and suppress an appended turn"
        )
    }

    private static func truncatedCodexLogIsForgotten(root: URL) async {
        let home = root.appendingPathComponent("truncated-codex")
        let file = home.appendingPathComponent("sessions/rollout.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = "2026-08-26T14:00:00.000Z"
        let lines = [
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"truncated-model"}}"#,
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("truncated-cache.sqlite"),
            env: ["CODEX_HOME": home.path],
            pricingOverlay: PricingOverlay()
        )
        let first = await service.refresh(.codex)
        Harness.expectEqual(first?.windowTokens, 100, "truncation fixture starts with cached usage")

        try? Data().write(to: file, options: .atomic)
        let truncated = await service.refresh(.codex)
        Harness.expectEqual(truncated?.windowTokens, 0, "truncating a tracked log removes its cached rows")
    }

    /// Codex counts cached reads and cache writes inside input_tokens, so a turn that reports all
    /// three must not be billed for the same token twice.
    private static func codexCacheBucketsAreCarvedOutOfInput(root: URL) async {
        let home = root.appendingPathComponent("carve-codex")
        let file = home.appendingPathComponent("sessions/2026/08/26/rollout-carve.jsonl")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let timestamp = "2026-08-26T12:00:00.000Z"
        let context = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"carve-model"}}"#
        // 100,000 prompt tokens: 60k served from cache, 10k written to it, 30k fresh.
        let usage = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":60000,"cache_write_input_tokens":10000,"output_tokens":0}}}}"#
        try? ([context, usage].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let service = CostService(
            databaseURL: root.appendingPathComponent("carve-cache.sqlite"),
            env: ["CODEX_HOME": home.path],
            pricingOverlay: PricingOverlay(userOverrides: [
                "carve-model": ModelPricing(input: 10, output: 0, cacheWrite: 1, cacheRead: 0),
            ])
        )
        let snapshot = await service.refresh(.codex)
        // 30k fresh at $10/M + 10k written at $1/M + 60k read at $0/M = $0.31.
        Harness.expectClose(
            snapshot?.windowCostUSD,
            0.31,
            "cached reads and cache writes are peeled out of input_tokens before pricing"
        )
        Harness.expectEqual(
            snapshot?.windowTokens,
            100_000,
            "peeling the buckets apart preserves the turn's total token count"
        )
    }
}

/// Rate-limit gate checks. The quota endpoints are shared with the CLIs, so a 429 has to stop
/// further requests until the window passes.
enum RateLimitTests {
    static func run() async {
        let gate = UsageRateLimitGate()
        let now = Date()

        Harness.expect(await gate.blocked(.claude, now: now) == nil, "a fresh gate blocks nothing")

        // No Retry-After: fall back to the default backoff.
        await gate.recordRateLimit(.claude, retryAfter: nil, now: now)
        let blocked = await gate.blocked(.claude, now: now)
        Harness.expect(blocked != nil, "a recorded 429 blocks the provider")
        Harness.expectEqual(
            blocked.map { Int($0.timeIntervalSince(now).rounded()) },
            300,
            "default backoff is five minutes"
        )

        // The other provider must be unaffected.
        Harness.expect(await gate.blocked(.codex, now: now) == nil, "the gate is per provider")

        // The window lifts on its own once it passes.
        Harness.expect(
            await gate.blocked(.claude, now: now.addingTimeInterval(301)) == nil,
            "the block expires after its window"
        )

        // A longer server-supplied window is honoured; a shorter one is floored at the default,
        // because we only get here by having asked too often already.
        await gate.recordRateLimit(.claude, retryAfter: now.addingTimeInterval(1800), now: now)
        Harness.expectEqual(
            (await gate.blocked(.claude, now: now)).map { Int($0.timeIntervalSince(now).rounded()) },
            1800,
            "a longer Retry-After is honoured"
        )
        await gate.recordRateLimit(.codex, retryAfter: now.addingTimeInterval(30), now: now)
        Harness.expectEqual(
            (await gate.blocked(.codex, now: now)).map { Int($0.timeIntervalSince(now).rounded()) },
            300,
            "a shorter Retry-After is floored at the default backoff"
        )

        await gate.recordSuccess(.claude)
        Harness.expect(await gate.blocked(.claude, now: now) == nil, "a success clears the block")
    }
}

/// Refreshes are scoped to the provider on screen, so each provider waits out its own minute.
enum ProviderRefreshCooldownTests {
    static func run() {
        var cooldowns = ProviderRefreshCooldown()

        // Everything the shown provider does — the poll, opening the menu, the Refresh row —
        // claims its gate and nothing else.
        Harness.expect(cooldowns.claimRefresh(.codex, at: 1_000), "the shown provider refreshes")
        Harness.expect(!cooldowns.claimRefresh(.codex, at: 1_030), "and then waits out its minute")
        Harness.expectEqual(
            cooldowns.remaining(.claude, at: 1_030),
            0,
            "the provider that is not shown is untouched by that refresh"
        )

        // Switching to the other provider is the one event that refreshes it.
        Harness.expect(cooldowns.claimRefresh(.claude, at: 1_030), "switching refreshes the provider switched to")

        // Switching back and forth cannot buy extra fetches: both gates are still running.
        Harness.expect(!cooldowns.claimRefresh(.codex, at: 1_040), "switching back does not refetch within the minute")
        Harness.expect(!cooldowns.claimRefresh(.claude, at: 1_050), "and neither does switching away and back")

        // Each gate elapses from its own last refresh, not from the other provider's.
        Harness.expect(cooldowns.claimRefresh(.codex, at: 1_059), "the first provider comes back a minute after its own refresh")
        Harness.expect(!cooldowns.claimRefresh(.claude, at: 1_059), "which says nothing about the other one")
        Harness.expect(cooldowns.claimRefresh(.claude, at: 1_089), "the other one comes back a minute after its own")

        // A forced refresh — a pricing edit the user is looking at — restarts only that provider.
        cooldowns.recordRefresh(.codex, at: 1_100)
        Harness.expectEqual(cooldowns.remaining(.codex, at: 1_100), 59, "a forced refresh restarts that provider's cooldown")
        Harness.expectEqual(cooldowns.remaining(.claude, at: 1_100), 48, "and leaves the other provider's running")

        // The interval is configurable, per provider, the same way the single gate's is.
        var tight = ProviderRefreshCooldown(minimumInterval: 10, tolerance: 0)
        Harness.expect(tight.claimRefresh(.codex, at: 0), "the first refresh runs")
        Harness.expect(!tight.claimRefresh(.codex, at: 9.999), "a custom interval is honoured")
        Harness.expect(tight.claimRefresh(.codex, at: 10), "and elapses exactly")
    }
}

/// What the Refresh row says while the cooldown runs.
enum RefreshRowPolicyTests {
    static func run() {
        let idle = RefreshRowPolicy.state(cooldownRemaining: 0, isRefreshing: false)
        Harness.expectEqual(idle.title, "Refresh", "an elapsed cooldown leaves the plain title")
        Harness.expectEqual(idle.trailingText, nil, "an elapsed cooldown leaves the shortcut column empty")
        Harness.expect(idle.isEnabled, "and the row accepts clicks")

        let waiting = RefreshRowPolicy.state(cooldownRemaining: 42, isRefreshing: false)
        Harness.expectEqual(waiting.title, "Refresh", "the cooldown keeps the plain title")
        Harness.expectEqual(waiting.trailingText, "42s", "the cooldown is spelled out in the shortcut column")
        Harness.expect(!waiting.isEnabled, "and the row refuses clicks it would drop")

        let recovery = RefreshRowPolicy.state(
            cooldownRemaining: 42,
            isRefreshing: false,
            allowsCredentialRecovery: true
        )
        Harness.expectEqual(recovery.title, "Refresh", "credential recovery keeps the existing row title")
        Harness.expectEqual(recovery.trailingText, nil, "credential recovery hides the API cooldown")
        Harness.expect(recovery.isEnabled, "credential recovery accepts an explicit user click")

        // Rounded up, so the last partial second never reads as a refresh that would be honoured.
        let sliver = RefreshRowPolicy.state(cooldownRemaining: 0.2, isRefreshing: false)
        Harness.expectEqual(sliver.trailingText, "1s", "a partial second still counts")
        Harness.expect(!sliver.isEnabled, "and still refuses clicks")

        // An in-flight refresh holds the cooldown too, but a countdown would misdescribe it.
        let running = RefreshRowPolicy.state(cooldownRemaining: 59, isRefreshing: true)
        Harness.expectEqual(running.title, "Refreshing…", "a running refresh says so")
        Harness.expectEqual(running.trailingText, nil, "a running refresh leaves the shortcut column empty")
        Harness.expect(!running.isEnabled, "and the row refuses a second one")
    }
}

/// Settings persistence and the refresh cadence table.
enum SettingsTests {
    @MainActor
    static func run() {
        // Fixed rather than PID-stamped: a name that changes per run leaves a new plist behind
        // in ~/Library/Preferences every time, since emptying a domain does not remove its file.
        let suite = "QuotaBarTests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Five minutes by default: the quota endpoints rate-limit, so a faster default would
        // reintroduce the 429 this cadence exists to avoid.
        let store = SettingsStore(defaults: defaults)
        Harness.expectEqual(store.refreshFrequency, .fiveMinutes, "default cadence")
        Harness.expectEqual(store.menuBarProvider, Provider.allCases[0], "one provider shows by default")
        Harness.expectEqual(store.costChartLabelMode, .tokens, "chart labels default to tokens")
        // The countdown is the reading nobody has to be taught, so it stays the one on first open.
        Harness.expectEqual(
            store.quotaResetDisplayMode,
            .countdown,
            "reset labels default to the countdown"
        )
        Harness.expectEqual(
            QuotaResetDisplayMode.countdown.toggled,
            .clock,
            "a click swaps the countdown for the clock"
        )
        Harness.expectEqual(
            QuotaResetDisplayMode.clock.toggled,
            .countdown,
            "a second click swaps back"
        )

        Harness.expectEqual(RefreshFrequency.manual.seconds, nil, "manual runs no timer")
        Harness.expectEqual(RefreshFrequency.thirtyMinutes.seconds, 1800, "thirty minutes in seconds")
        Harness.expectEqual(RefreshFrequency.allCases.count, 6, "six cadence options")

        // A pick on the card's switch publishes exactly the provider picked.
        var switches: [Provider] = []
        let observer = store.$menuBarProvider
            .dropFirst()
            .sink { switches.append($0) }

        store.refreshFrequency = .fifteenMinutes
        store.menuBarProvider = .claude
        Harness.expectEqual(switches, [.claude], "a switch publishes the picked provider once")
        _ = observer

        store.costChartLabelMode = .cost
        store.quotaResetDisplayMode = .clock

        let reloaded = SettingsStore(defaults: defaults)
        Harness.expectEqual(reloaded.refreshFrequency, .fifteenMinutes, "cadence survives a reload")
        Harness.expectEqual(reloaded.menuBarProvider, .claude, "the shown provider survives a reload")
        Harness.expectEqual(reloaded.costChartLabelMode, .cost, "chart label mode survives a reload")
        Harness.expectEqual(
            reloaded.quotaResetDisplayMode,
            .clock,
            "the reset label face survives a reload"
        )

        // A machine upgrading from the two-toggle build keeps the item it had left enabled.
        let legacySuite = "\(suite)-legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite) ?? .standard
        legacyDefaults.removePersistentDomain(forName: legacySuite)
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(false, forKey: "provider.codex.enabled")
        legacyDefaults.set(true, forKey: "provider.claude.enabled")
        Harness.expectEqual(
            SettingsStore(defaults: legacyDefaults).menuBarProvider,
            .claude,
            "the single remaining legacy item becomes the shown provider"
        )
    }
}

/// Pace projection: expected usage is linear in elapsed window time, and the delta against
/// actual usage becomes the deficit/reserve line under each bar.
enum PaceTests {
    private static let week: TimeInterval = 7 * 24 * 3600
    private static let weekMinutes = 10_080

    private static func window(used: Double, secondsUntilReset: TimeInterval, now: Date) -> UsageWindow {
        UsageWindow(
            usedPercent: used,
            resetsAt: now.addingTimeInterval(secondsUntilReset),
            windowSeconds: Self.weekMinutes * 60
        )
    }

    /// Plain "1d 12h" rendering so the label assertions do not depend on the UI formatter.
    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    static func run() {
        let now = Date()

        // Halfway through the window with half the budget spent is exactly on pace.
        let onPace = UsagePace.evaluate(
            window: Self.window(used: 50, secondsUntilReset: Self.week / 2, now: now),
            context: .weekly,
            now: now
        )
        Harness.expectEqual(onPace?.stage, .onTrack, "half spent at halfway is on track")
        Harness.expectEqual(onPace?.deltaLabel, "On pace", "on-track label")

        // Spending faster than the clock is a deficit, and the budget empties before the reset.
        let deficit = UsagePace.evaluate(
            window: Self.window(used: 70, secondsUntilReset: Self.week / 2, now: now),
            context: .weekly,
            now: now
        )
        Harness.expectEqual(deficit?.stage, .farAhead, "20 points over expected is far ahead")
        Harness.expectEqual(deficit?.deltaLabel, "20% in deficit", "deficit label")
        Harness.expect(deficit?.willLastToReset == false, "a deficit does not last to the reset")
        Harness.expectEqual(
            deficit?.etaLabel(context: .weekly, durationText: Self.duration),
            "Runs out in 1d 12h",
            "weekly ETA wording"
        )
        // The session window says "projected empty" rather than "runs out".
        Harness.expectEqual(
            deficit?.etaLabel(context: .session, durationText: Self.duration),
            "Projected empty in 1d 12h",
            "session ETA wording"
        )

        // Spending slower banks a reserve, and the headroom hint appears past 15 points.
        let reserve = UsagePace.evaluate(
            window: Self.window(used: 30, secondsUntilReset: Self.week / 2, now: now),
            context: .weekly,
            now: now
        )
        Harness.expectEqual(reserve?.stage, .farBehind, "20 points under expected is far behind")
        Harness.expectEqual(reserve?.deltaLabel, "20% in reserve", "reserve label")
        Harness.expect(reserve?.willLastToReset == true, "a reserve lasts to the reset")
        Harness.expectEqual(
            reserve?.etaLabel(context: .weekly, durationText: Self.duration),
            "Lasts until reset · 1.5× headroom",
            "headroom hint at a large reserve"
        )

        // A small reserve gets the plain label, with no headroom claim.
        let smallReserve = UsagePace.evaluate(
            window: Self.window(used: 45, secondsUntilReset: Self.week / 2, now: now),
            context: .weekly,
            now: now
        )
        Harness.expectEqual(smallReserve?.stage, .slightlyBehind, "5 points under is slightly behind")
        Harness.expectEqual(
            smallReserve?.etaLabel(context: .weekly, durationText: Self.duration),
            "Lasts until reset",
            "no headroom hint for a small reserve"
        )

        // The bar shows what is left, so the tip is placed on the remaining side.
        Harness.expectEqual(onPace?.expectedRemainingPercent, 50, "pace tip position mirrors expected use")

        // Guards: each of these would produce a misleading reading.
        Harness.expect(
            UsagePace.evaluate(
                window: UsageWindow(usedPercent: 50, resetsAt: nil, windowSeconds: nil),
                context: .weekly,
                now: now
            ) == nil,
            "no reset time means no pace"
        )
        Harness.expect(
            UsagePace.evaluate(
                window: Self.window(used: 100, secondsUntilReset: Self.week / 2, now: now),
                context: .weekly,
                now: now
            ) == nil,
            "an exhausted window has no pace to report"
        )
        Harness.expect(
            UsagePace.evaluate(
                window: Self.window(used: 50, secondsUntilReset: -60, now: now),
                context: .weekly,
                now: now
            ) == nil,
            "a reset in the past is rejected"
        )
        Harness.expect(
            UsagePace.evaluate(
                window: Self.window(used: 50, secondsUntilReset: Self.week * 2, now: now),
                context: .weekly,
                now: now
            ) == nil,
            "a reset further out than one window is rejected"
        )
        // Just after a reset the expected figure is rounding noise, so nothing is shown.
        Harness.expect(
            UsagePace.evaluate(
                window: Self.window(used: 1, secondsUntilReset: Self.week * 0.99, now: now),
                context: .weekly,
                now: now
            ) == nil,
            "under 3% elapsed is too early to judge"
        )

        // Stage boundaries, straight from CodexBar's thresholds.
        Harness.expectEqual(UsagePace.stage(for: 2), .onTrack, "2 points is still on track")
        Harness.expectEqual(UsagePace.stage(for: 6), .slightlyAhead, "6 points is slightly ahead")
        Harness.expectEqual(UsagePace.stage(for: -12), .behind, "12 points under is behind")
        Harness.expectEqual(UsagePace.stage(for: 12.1), .farAhead, "past 12 points is far ahead")
    }
}

/// The historical pace model: sampling, week reconstruction, and the regression that replaces
/// the linear expectation once enough complete windows exist.
enum HistoricalPaceTests {
    private static let weekSeconds: TimeInterval = 7 * 24 * 3600
    private static let weekMinutes = 10_080

    /// A synthetic completed window whose usage follows `shape(u)`, sampled at 11 points so it
    /// clears both the sample-count floor and the boundary-coverage test.
    private static func records(
        resetsAt: Date,
        shape: (Double) -> Double
    ) -> [UsageHistoryRecord] {
        let windowStart = resetsAt.addingTimeInterval(-Self.weekSeconds)
        return stride(from: 0.0, through: 1.0, by: 0.1).map { u in
            UsageHistoryRecord(
                provider: .codex,
                sampledAt: windowStart.addingTimeInterval(u * Self.weekSeconds),
                usedPercent: shape(u),
                resetsAt: resetsAt,
                windowMinutes: Self.weekMinutes
            )
        }
    }

    static func run() {
        Self.samplingGate()
        Self.curveReconstruction()
        Self.completeness()
        Self.helpers()
        Self.regression()
    }

    private static func samplingGate() {
        let now = Date()
        let base = UsageHistoryRecord(
            provider: .codex,
            sampledAt: now,
            usedPercent: 40,
            resetsAt: now.addingTimeInterval(Self.weekSeconds),
            windowMinutes: Self.weekMinutes
        )
        Harness.expect(UsageHistoryStore.shouldWrite(base, after: nil), "the first sample is always kept")

        // Same reading a few minutes later is not worth a row.
        let soon = UsageHistoryRecord(
            provider: .codex,
            sampledAt: now.addingTimeInterval(300),
            usedPercent: 40.2,
            resetsAt: base.resetsAt,
            windowMinutes: Self.weekMinutes
        )
        Harness.expect(!UsageHistoryStore.shouldWrite(soon, after: base), "a tiny change soon after is skipped")

        // A whole point of movement is worth recording immediately.
        let moved = UsageHistoryRecord(
            provider: .codex,
            sampledAt: now.addingTimeInterval(300),
            usedPercent: 41.5,
            resetsAt: base.resetsAt,
            windowMinutes: Self.weekMinutes
        )
        Harness.expect(UsageHistoryStore.shouldWrite(moved, after: base), "a one-point move is recorded")

        // And so is the passage of the write interval.
        let later = UsageHistoryRecord(
            provider: .codex,
            sampledAt: now.addingTimeInterval(31 * 60),
            usedPercent: 40.1,
            resetsAt: base.resetsAt,
            windowMinutes: Self.weekMinutes
        )
        Harness.expect(UsageHistoryStore.shouldWrite(later, after: base), "the write interval forces a sample")
    }

    private static func curveReconstruction() {
        let resetsAt = Date()
        let windowStart = resetsAt.addingTimeInterval(-Self.weekSeconds)
        // A dip mid-week must not survive: cumulative usage only goes up.
        let samples = Self.records(resetsAt: resetsAt) { u in u < 0.5 ? u * 100 : max(0, 50 - (u - 0.5) * 20) }
        guard let curve = UsageHistoryStore.reconstructCurve(
            samples: samples,
            windowStart: windowStart,
            duration: Self.weekSeconds
        ) else {
            Harness.expect(false, "curve reconstruction returned nil")
            return
        }

        Harness.expectEqual(curve.count, UsageWeekProfile.gridPointCount, "curve lands on the fixed grid")
        Harness.expectEqual(curve.first, 0, "the curve is anchored at zero on the window start")
        Harness.expect(
            zip(curve, curve.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 },
            "the curve is monotone despite a dip in the samples"
        )
        Harness.expect(curve.last! >= 49.9, "the curve holds the peak through the reset")
    }

    private static func completeness() {
        let resetsAt = Date()
        let windowStart = resetsAt.addingTimeInterval(-Self.weekSeconds)
        let full = Self.records(resetsAt: resetsAt) { $0 * 100 }
        Harness.expect(
            UsageHistoryStore.isComplete(samples: full, windowStart: windowStart, resetsAt: resetsAt),
            "a fully sampled window is complete"
        )

        // Too few samples cannot describe a shape.
        Harness.expect(
            !UsageHistoryStore.isComplete(
                samples: Array(full.prefix(3)),
                windowStart: windowStart,
                resetsAt: resetsAt
            ),
            "three samples is not a complete window"
        )

        // A window first observed on day five would look like a very light week.
        let lateOnly = full.filter { $0.sampledAt.timeIntervalSince(windowStart) > 5 * 86_400 }
        Harness.expect(
            !UsageHistoryStore.isComplete(samples: lateOnly, windowStart: windowStart, resetsAt: resetsAt),
            "a window missing its start is rejected"
        )

        // Incomplete weeks must not reach the dataset at all.
        let dataset = UsageHistoryStore.buildDataset(from: Array(full.prefix(3)))
        Harness.expect(dataset == nil, "an incomplete week yields no dataset")
    }

    private static func helpers() {
        Harness.expectEqual(
            HistoricalUsagePace.interpolate(curve: [0, 50, 100], at: 0.25),
            25,
            "interpolation between grid points"
        )
        Harness.expectEqual(
            HistoricalUsagePace.weightedMedian(values: [10, 20, 30], weights: [1, 1, 8]),
            30,
            "weight dominates the median"
        )
        Harness.expectEqual(
            HistoricalUsagePace.weightedMedian(values: [10, 20, 30], weights: [1, 1, 1]),
            20,
            "equal weights give the plain median"
        )

        // A week that hit the cap early carries no rate information past that point, so the
        // tail is replaced by the average slope that got it there.
        let capped = [0.0, 50.0, 100.0, 100.0, 100.0]
        let extended = HistoricalUsagePace.extendPastCap(capped)
        Harness.expect(extended.last! > 100, "the capped tail is extrapolated past the cap")

        // Crossing detection: a curve shifted to meet current usage reaches 100 partway.
        let crossing = HistoricalUsagePace.firstCrossing(
            after: 0,
            curve: [0, 25, 50, 75, 100],
            shift: 50,
            actualAtNow: 50
        )
        Harness.expect(crossing != nil, "a shifted curve that reaches the cap reports a crossing")
        Harness.expect((crossing ?? 1) <= 0.55, "the crossing lands where the shifted curve hits 100")
    }

    private static func regression() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(Self.weekSeconds / 2)
        let current = UsageWindow(
            usedPercent: 50,
            resetsAt: resetsAt,
            windowSeconds: Self.weekMinutes * 60
        )

        // Past weeks that spend late: 20% by mid-week, everything by the reset.
        func backLoaded(_ weeksAgo: Int) -> [UsageHistoryRecord] {
            Self.records(resetsAt: resetsAt.addingTimeInterval(-Double(weeksAgo) * Self.weekSeconds)) { u in
                u <= 0.5 ? u * 40 : 20 + (u - 0.5) * 160
            }
        }

        // Two weeks of history is not enough to displace the linear model.
        let thin = UsageHistoryStore.buildDataset(from: (1...2).flatMap(backLoaded))
        Harness.expect(
            HistoricalUsagePace.evaluate(window: current, dataset: thin, now: now) == nil,
            "under three weeks the historical model stays silent"
        )

        guard let four = UsageHistoryStore.buildDataset(from: (1...4).flatMap(backLoaded)),
              let pace = HistoricalUsagePace.evaluate(window: current, dataset: four, now: now) else {
            Harness.expect(false, "four weeks of history should produce a pace")
            return
        }
        Harness.expectEqual(four.weeks.count, 4, "four complete weeks are recognised")
        // Halfway through, history says 20% is normal, so 50% spent is a deficit -- where the
        // linear model would have called this exactly on pace.
        Harness.expect(pace.expectedUsedPercent < 50, "history lowers the expectation below linear")
        Harness.expect(pace.stage.isAhead, "spending at the linear rate reads as a deficit here")
        Harness.expect(pace.runOutProbability == nil, "risk needs five weeks, not four")

        guard let five = UsageHistoryStore.buildDataset(from: (1...5).flatMap(backLoaded)),
              let withRisk = HistoricalUsagePace.evaluate(window: current, dataset: five, now: now) else {
            Harness.expect(false, "five weeks of history should produce a pace")
            return
        }
        Harness.expect(withRisk.runOutProbability != nil, "five weeks unlocks the risk figure")

        // Every past week ran the window dry from here, so this one is projected to as well.
        Harness.expect(!withRisk.willLastToReset, "a history of running dry projects running dry")
        Harness.expect(withRisk.etaSeconds != nil, "a projected run-out carries an ETA")
    }
}

/// The hand-edited price layer: round-trips through disk and outranks the other layers.
enum PricingOverrideTests {
    static func run() {
        let url = PricingOverlayStore.userOverridesURL
        // Never clobber a real override file while testing.
        let backup = try? Data(contentsOf: url)
        defer {
            if let backup {
                try? backup.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let overrides: [String: ModelPricing] = [
            "ox-alpha": ModelPricing(input: 1.5, output: 6, cacheWrite: 1.875, cacheRead: 0.15),
            "claude-opus-5": ModelPricing(input: 99, output: 99),
            // Everything the billing math reads, so an override cannot silently drop a tier.
            "ox-tiered": ModelPricing(
                input: 2, output: 12, cacheWrite: 2.5, cacheWrite1h: 3.5, cacheRead: 0.2,
                thresholdTokens: 200_000,
                inputAbove: 4, outputAbove: 18, cacheWriteAbove: 5,
                cacheWrite1hAbove: 7, cacheReadAbove: 0.4
            ),
        ]
        do {
            try PricingOverlayStore.saveUserOverrides(overrides)
        } catch {
            Harness.expect(false, "saving overrides threw: \(error)")
            return
        }

        let loaded = PricingOverlayStore.loadUserOverrides()
        Harness.expectEqual(loaded["ox-alpha"]?.input, 1.5, "override input rate round-trips")
        Harness.expectEqual(loaded["ox-alpha"]?.cacheRead, 0.15, "override cache rate round-trips")
        Harness.expectEqual(loaded.count, 3, "every override round-trips")
        Harness.expectEqual(loaded["ox-tiered"], overrides["ox-tiered"], "the full rate set round-trips")

        // A model with no built-in price becomes priceable through the override alone.
        let overlay = PricingOverlay(userOverrides: loaded, modelsDev: [:])
        Harness.expectEqual(
            CostPricing.cost(
                totals: TokenTotals(input: 1_000_000),
                model: "ox-alpha",
                provider: .claude,
                longContext: false,
                overlay: overlay
            ),
            1.5,
            "an override prices a model the built-in table does not know"
        )
        // And it outranks a built-in rate for a model that does have one.
        Harness.expectEqual(
            CostPricing.pricing(for: "claude-opus-5", provider: .claude, overlay: overlay)?.input,
            99,
            "an override outranks the built-in table"
        )

        // A one-hour cache write is billed at its own rate when the override states one, and at
        // twice input when it does not.
        let hourly = TokenTotals(cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)
        Harness.expectEqual(
            CostPricing.cost(
                totals: hourly, model: "ox-tiered", provider: .codex,
                longContext: false, overlay: overlay
            ),
            3.5,
            "a stated one-hour rate is what bills"
        )
        Harness.expectEqual(
            CostPricing.cost(
                totals: hourly, model: "ox-tiered", provider: .codex,
                longContext: true, overlay: overlay
            ),
            7,
            "the long-context one-hour rate applies above the threshold"
        )
        Harness.expectEqual(
            CostPricing.cost(
                totals: hourly, model: "ox-alpha", provider: .claude,
                longContext: false, overlay: overlay
            ),
            3,
            "no stated one-hour rate falls back to twice input"
        )
        Harness.expect(
            CostPricing.isLongContext(
                totals: TokenTotals(input: 250_000), model: "ox-tiered",
                provider: .codex, overlay: overlay
            ),
            "an overridden threshold decides the tier"
        )

        // Saving nothing removes the file, handing control back to the lower layers.
        try? PricingOverlayStore.saveUserOverrides([:])
        Harness.expect(
            !FileManager.default.fileExists(atPath: url.path),
            "an empty override set deletes the file"
        )
        Harness.expectEqual(
            CostPricing.pricing(for: "claude-opus-5", provider: .claude)?.input,
            5,
            "the built-in rate returns once the override is gone"
        )
    }
}
