import Darwin
import Foundation

/// Turns Pi Agent's session files into observed requests. Pi Agent copies history into forked
/// sessions, so the session directory is read whole whenever any of its files changes and each
/// message is keyed by the entry id it keeps across forks. Its logs carry no Fast signal, so every
/// request is Standard.
package struct PiAgentAdapter: SnapshotAdapter {
    /// Identity of every session file at the moment it was examined.
    package struct Stamp: Hashable {
        fileprivate let directory: String
        fileprivate let files: [SessionFile]
    }

    fileprivate struct SessionFile: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Double
        let changed: Double
    }

    package var source: CostUsageSource { .piAgent }
    private let env: [String: String]
    private let agentDirectory: URL
    private let sessionsDirectory: URL

    package init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        self.agentDirectory = Self.agentDirectory(env: env)
        self.sessionsDirectory = Self.sessionsDirectory(agentDirectory: self.agentDirectory, env: env)
    }

    package func survey() -> SnapshotSurvey<Stamp> {
        guard FileManager.default.fileExists(atPath: self.sessionsDirectory.path) else { return .absent }
        let eligibility = ExternalAgentEligibility.signIn(
            authFile: self.agentDirectory.appendingPathComponent("auth.json"),
            entry: "openai-codex",
            env: self.env
        )
        guard let (included, status) = eligibility.resolved else { return .failed(reason: "auth") }
        guard let files = try? self.sessionFiles() else { return .failed(reason: "sessions") }
        return .present(stamp: self.stamp(of: files), included: included, status: status)
    }

    package func requests() throws -> [ObservedRequest] {
        do {
            var requests: [ObservedRequest] = []
            for url in try self.sessionFiles() {
                _ = try LogFileScanner.readLines(of: url, from: 0) { line in
                    // Only assistant messages from the openai-codex provider become requests. Most
                    // lines are prompts and tool output, so check for the provider name before parsing.
                    guard Self.mentionsCodexProvider(line),
                          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let request = Self.request(from: object) else { return }
                    requests.append(request)
                }
            }
            return requests
        } catch {
            throw SnapshotReadError("sessions")
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
        return Stamp(directory: self.sessionsDirectory.path, files: entries)
    }

    private static let codexProvider = Array("openai-codex".utf8)

    private static func mentionsCodexProvider(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return self.codexProvider.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count) != nil
        }
    }

    private static func request(from object: [String: Any]) -> ObservedRequest? {
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
        return ObservedRequest(key: identifier, timestamp: date, model: rawModel, tokens: totals, isFast: false)
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
