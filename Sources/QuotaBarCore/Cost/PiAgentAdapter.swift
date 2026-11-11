import CryptoKit
import Darwin
import Foundation

/// Turns Pi Agent's session files into observed requests. Pi Agent copies history into forked
/// sessions, so the session directory is read whole whenever any of its files changes and each
/// message is keyed by immutable facts it keeps across forks. Its logs carry no Fast signal, so every
/// request is Standard.
package struct PiAgentAdapter: SnapshotAdapter {
    /// Identity of every session file at the moment it was examined.
    package struct Stamp: Hashable {
        fileprivate let directory: String
        fileprivate let files: [String: FileStamp]
    }

    package var source: SnapshotSource { .piAgent }
    private let sessionsDirectory: URL

    package init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.sessionsDirectory = Self.sessionsDirectory(agentDirectory: Self.agentDirectory(env: env), env: env)
    }

    package func survey() -> SnapshotSurvey<Stamp> {
        guard FileManager.default.fileExists(atPath: self.sessionsDirectory.path) else { return .absent }
        do {
            return .present(stamp: self.stamp(of: try self.sessionFiles()), included: true, status: .idle)
        } catch {
            return .failed(.sessions)
        }
    }

    package func requests() throws -> [ObservedRequest] {
        do {
            var requests: [ObservedRequest] = []
            for url in try self.sessionFiles() {
                _ = try LogFileScanner.readLines(of: url, from: 0) { line in
                    // Prompts and tool output have no usage; avoid JSON decoding those lines.
                    guard Self.mentionsUsage(line),
                          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let request = Self.request(from: object) else { return }
                    requests.append(request)
                }
            }
            return requests
        } catch {
            throw SnapshotReadError(.sessions, underlying: error)
        }
    }

    private func sessionFiles() throws -> [URL] {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: self.sessionsDirectory,
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

    /// Nil when any file cannot be examined, so the directory is read regardless.
    private func stamp(of files: [URL]) -> Stamp? {
        var entries: [String: FileStamp] = [:]
        entries.reserveCapacity(files.count)
        for url in files {
            guard let stamp = try? FileStamp.examine(url.path) else { return nil }
            entries[url.path] = stamp
        }
        return Stamp(directory: self.sessionsDirectory.path, files: entries)
    }

    private static let usageMarker = Array("usage".utf8)

    private static func mentionsUsage(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return self.usageMarker.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count) != nil
        }
    }

    private static func request(from object: [String: Any]) -> ObservedRequest? {
        guard let type = object["type"] as? String else { return nil }
        let message: [String: Any]
        switch type {
        case "message":
            guard let value = object["message"] as? [String: Any],
                  value["role"] as? String == "assistant" else { return nil }
            message = value
        case "usage", "compaction", "branch_summary":
            // SessionManager 1.5.1 writes UsageEntry.provider/model/usage. Summary entries
            // normally have only usage, with no model identity: never infer their model from
            // the session's current selection, since extensions may use a different model.
            message = object
        default: return nil
        }
        guard let usage = message["usage"] as? [String: Any],
              let rawModel = message["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let date = self.date(message: message, object: object) else { return nil }
        let provider = (message["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let totals = TokenTotals(
            input: self.nonnegativeInt(usage["input"]),
            output: self.nonnegativeInt(usage["output"]),
            cacheWrite: self.nonnegativeInt(usage["cacheWrite"]),
            cacheWrite1h: self.nonnegativeInt(usage["cacheWrite1h"]),
            cacheRead: self.nonnegativeInt(usage["cacheRead"])
        )
        guard totals.hasValidCounts, totals.total > 0 else { return nil }
        // Entry IDs are 8-hex values unique within a session. Immutable message facts make
        // collisions across sessions distinct, while fork copies retain exactly this identity.
        guard let identifier = object["id"] as? String, !identifier.isEmpty else { return nil }
        let facts = [identifier, String(date.timeIntervalSince1970.bitPattern), provider ?? "", rawModel]
        guard let encoded = try? JSONEncoder().encode(facts) else { return nil }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let cost = usage["cost"] as? [String: Any]
        let total = (cost?["total"] as? NSNumber).flatMap { value -> Double? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        return ObservedRequest(key: "pi-v2:" + digest, timestamp: date, model: rawModel,
                               tokens: totals, isFast: false, upstreamProvider: provider,
                               loggedCostUSD: total, totalFromProvider: cost?["totalFromProvider"] as? Bool,
                               entryID: identifier)
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
