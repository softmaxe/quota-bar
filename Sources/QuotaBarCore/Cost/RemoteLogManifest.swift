import Foundation

/// Evidence committed with the tokens and cursor, never imported independently of them.
package struct RemoteLogVersion: Codable, Sendable {
    package let path: String
    package let size: Int64
    package let digest: String
    package let state: String?
    package let observedAt: Date
    package let validJSON: Bool
    package let complete: Bool
    package var evictionPending: Bool

    package init(path: String, size: Int64, digest: String, state: String?, observedAt: Date,
                 validJSON: Bool, complete: Bool, evictionPending: Bool) {
        self.path = path
        self.size = size
        self.digest = digest
        self.state = state
        self.observedAt = observedAt
        self.validJSON = validJSON
        self.complete = complete
        self.evictionPending = evictionPending
    }

    package func matches(_ cursor: FileCursor?) -> Bool {
        guard let cursor else { return false }
        return cursor.size == size && cursor.offset == size && cursor.resumeStateJSON == state
    }
}

extension CostCache {
    func remoteVersions() throws -> [RemoteLogVersion] {
        var versions: [RemoteLogVersion] = []
        try self.recordedUsageReader.query("SELECT path, value FROM remote_manifest") { statement in
            guard let path = FileCursor.text(statement, column: 0),
                  let value = FileCursor.text(statement, column: 1) else {
                throw RemoteSyncError.failed("Invalid remote manifest row")
            }
            let version = try JSONDecoder().decode(RemoteLogVersion.self, from: Data(value.utf8))
            guard version.path == path, version.size > 0, version.digest.count == 64,
                  version.digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw RemoteSyncError.failed("Invalid remote manifest evidence")
            }
            versions.append(version)
        }
        return versions
    }

    func saveRemoteVersion(_ version: RemoteLogVersion) throws {
        let value = String(decoding: try JSONEncoder().encode(version), as: UTF8.self)
        try self.recordedUsageReader.query(
            "INSERT OR REPLACE INTO remote_manifest(path, value) VALUES (?, ?)",
            bindings: [version.path, value]
        ) { _ in }
    }
}
