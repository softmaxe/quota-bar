import Darwin
import Foundation

enum PiAgentLogScanner {
    struct Result {
        let touched: Int
        let status: PiAgentScanStatus
        /// The session files this result was read from, when every row was stored. Passing it to
        /// the next scan lets an unchanged session directory skip the full re-read.
        var sessions: SessionSnapshot? = nil
    }

    /// Identity of every session file at the moment it was read. Rows are upserted by their
    /// message key and an identical row is left untouched, so re-reading unchanged files cannot
    /// change the store. The time zone is included because it decides each row's day.
    struct SessionSnapshot: Equatable {
        fileprivate let directory: String
        fileprivate let timeZone: String
        fileprivate let files: [SessionFile]
    }

    fileprivate struct SessionFile: Equatable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Double
        let changed: Double
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

    static func scan(
        cache: CostCache,
        overlay: PricingOverlay?,
        book: PriceBook = .bundled,
        env: [String: String],
        previous: SessionSnapshot? = nil
    ) -> Result {
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
                overlay: overlay,
                book: book,
                previous: previous
            )
        }
        return Result(touched: 0, status: .error("auth"))
    }

    private static func scanSessions(
        _ directory: URL,
        eligibility: ExternalAgentEligibility,
        cache: CostCache,
        overlay: PricingOverlay?,
        book: PriceBook,
        previous: SessionSnapshot?
    ) -> Result {
        do {
            let files = try self.sessionFiles(in: directory)
            let snapshot = self.snapshot(of: files, in: directory)
            guard let (included, status) = eligibility.resolved else {
                return Result(touched: 0, status: .error("auth"))
            }
            if let snapshot, snapshot == previous {
                return Result(touched: 0, status: status, sessions: snapshot)
            }
            let rows = try self.readRows(from: files)

            try cache.beginTransaction()
            do {
                for row in rows {
                    let model = CostPricing.normalizeCodexModel(row.model)
                    let pricing = CostPricing.pricing(
                        forNormalizedModel: model,
                        provider: .codex,
                        day: row.day,
                        overlay: overlay,
                        book: book
                    )
                    try cache.addPiMessage(
                        key: row.key,
                        included: included,
                        day: row.day,
                        model: model,
                        longContext: CostPricing.isLongContext(totals: row.totals, pricing: pricing),
                        totals: row.totals
                    )
                }
                try cache.commit()
            } catch {
                cache.rollback()
                throw error
            }
            return Result(touched: rows.count, status: status, sessions: snapshot)
        } catch {
            return Result(touched: 0, status: .error("sessions"))
        }
    }

    private static func sessionFiles(in directory: URL) throws -> [URL] {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw ScanError.read }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        if enumerationFailed { throw ScanError.read }
        return files
    }

    /// Nil when any file cannot be examined, so the scan reads everything and reports the error.
    private static func snapshot(of files: [URL], in directory: URL) -> SessionSnapshot? {
        var entries: [SessionFile] = []
        entries.reserveCapacity(files.count)
        for url in files {
            var info = Darwin.stat()
            guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { return nil }
            entries.append(SessionFile(
                path: url.path,
                device: info.st_dev,
                inode: info.st_ino,
                size: info.st_size,
                modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                changed: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
            ))
        }
        return SessionSnapshot(
            directory: directory.path,
            timeZone: TimeZone.current.identifier,
            files: entries
        )
    }

    private static func readRows(from files: [URL]) throws -> [Row] {
        var rows: [Row] = []
        for url in files {
            _ = try LogFileScanner.readLines(of: url, from: 0) { line in
                // Only assistant messages from the openai-codex provider become rows. Most lines
                // are prompts and tool output, so check for the provider name before parsing.
                guard self.mentionsCodexProvider(line),
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let row = self.row(from: object) else { return }
                rows.append(row)
            }
        }
        return rows
    }

    private static let codexProvider = Array("openai-codex".utf8)

    private static func mentionsCodexProvider(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return self.codexProvider.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count) != nil
        }
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
