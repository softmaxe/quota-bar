import Foundation

enum PiAgentLogScanner {
    struct Result {
        let touched: Int
        let status: PiAgentScanStatus
    }

    private struct PiAuth: Decodable {
        let openAICodex: Entry?
        struct Entry: Decodable { let type: String?; let accountId: String? }
        enum CodingKeys: String, CodingKey { case openAICodex = "openai-codex" }
    }

    private struct Row {
        let key: String
        let day: String
        let model: String
        let totals: TokenTotals
    }

    static func scan(cache: CostCache, overlay: PricingOverlay?, env: [String: String]) -> Result {
        let agentDirectory = self.agentDirectory(env: env)
        let sessionsDirectory = self.sessionsDirectory(agentDirectory: agentDirectory, env: env)
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
            return Result(touched: 0, status: .idle)
        }

        let eligibility = self.eligibility(agentDirectory: agentDirectory, env: env)
        guard case .indeterminate = eligibility else {
            return self.scanSessions(
                sessionsDirectory,
                eligibility: eligibility,
                cache: cache,
                overlay: overlay
            )
        }
        return Result(touched: 0, status: .error("auth"))
    }

    private static func scanSessions(
        _ directory: URL,
        eligibility: ExternalAgentEligibility,
        cache: CostCache,
        overlay: PricingOverlay?
    ) -> Result {
        do {
            let rows = try self.readRows(in: directory)
            guard let (included, status) = eligibility.resolved else {
                return Result(touched: 0, status: .error("auth"))
            }

            try cache.beginTransaction()
            do {
                for row in rows {
                    let model = CostPricing.normalizeCodexModel(row.model)
                    let pricing = CostPricing.pricing(
                        forNormalizedModel: model,
                        provider: .codex,
                        overlay: overlay
                    )
                    let longContext = CostPricing.isLongContext(totals: row.totals, pricing: pricing)
                    let cost = pricing?.cost(for: row.totals, longContext: longContext)
                    try cache.addPiMessage(
                        key: row.key,
                        included: included,
                        day: row.day,
                        model: model,
                        longContext: longContext,
                        totals: row.totals,
                        costUSD: cost
                    )
                }
                try cache.commit()
            } catch {
                cache.rollback()
                throw error
            }
            return Result(touched: rows.count, status: status)
        } catch {
            return Result(touched: 0, status: .error("sessions"))
        }
    }

    private static func readRows(in directory: URL) throws -> [Row] {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw ScanError.read }

        var rows: [Row] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            _ = try LogFileScanner.readLines(of: url, from: 0) { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let row = self.row(from: object) else { return }
                rows.append(row)
            }
        }
        if enumerationFailed { throw ScanError.read }
        return rows
    }

    private static func row(from object: [String: Any]) -> Row? {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              message["provider"] as? String == "openai-codex",
              let usage = message["usage"] as? [String: Any],
              let rawModel = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawModel.isEmpty,
              let date = self.date(message: message, object: object) else { return nil }
        let totals = TokenTotals(
            input: self.nonnegativeInt(usage["input"]),
            output: self.nonnegativeInt(usage["output"]),
            cacheWrite: self.nonnegativeInt(usage["cacheWrite"]),
            cacheWrite1h: self.nonnegativeInt(usage["cacheWrite1h"]),
            cacheRead: self.nonnegativeInt(usage["cacheRead"])
        )
        guard totals.total > 0 else { return nil }
        // Session entries use UUIDv7 identifiers that survive forks. Keying globally prevents a
        // copied history from billing the same model response twice.
        let identifier = (object["id"] as? String) ?? (message["id"] as? String)
        guard let identifier, !identifier.isEmpty else { return nil }
        return Row(key: identifier, day: DayKey.make(from: date), model: rawModel, totals: totals)
    }

    private static func date(message: [String: Any], object: [String: Any]) -> Date? {
        if let milliseconds = (message["timestamp"] as? NSNumber)?.doubleValue, milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let timestamp = object["timestamp"] as? String else { return nil }
        return ISO8601.parse(timestamp)
    }

    private static func nonnegativeInt(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }

    private static func eligibility(
        agentDirectory: URL,
        env: [String: String]
    ) -> ExternalAgentEligibility {
        do {
            let piData = try Data(contentsOf: agentDirectory.appendingPathComponent("auth.json"))
            let codexAccountId = try CodexCredentialsStore.accountId(env: env)
            guard let pi = try JSONDecoder()
                .decode(PiAuth.self, from: piData).openAICodex else { return .indeterminate }
            return .matchingCodexAccount(
                type: pi.type,
                accountId: pi.accountId,
                codexAccountId: codexAccountId
            )
        } catch {
            return .indeterminate
        }
    }

    private static func agentDirectory(env: [String: String]) -> URL {
        if let explicit = self.nonempty(env["PI_CODING_AGENT_DIR"]) {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let home = self.nonempty(env["HOME"])
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    private static func sessionsDirectory(agentDirectory: URL, env: [String: String]) -> URL {
        guard let explicit = self.nonempty(env["PI_CODING_AGENT_SESSION_DIR"]) else {
            return agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private enum ScanError: Error { case read }
}
