import Darwin
import Foundation
import SQLite3

package enum CostDatabaseLocation {
    package static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar/cost-usage", isDirectory: true)
            .appendingPathComponent("cost-usage.sqlite", isDirectory: false)
    }

    package static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/QuotaBar/cost-usage", isDirectory: true)
            .appendingPathComponent("cost-usage.sqlite", isDirectory: false)
    }

    /// Copies the legacy database once. SQLite's backup API includes committed pages still in WAL.
    package static func migrateIfNeeded(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        guard fileManager.fileExists(atPath: source.path) else { return }

        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let temporary = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).migration-\(UUID().uuidString)",
            isDirectory: false
        )
        let temporaryArtifacts = [
            temporary,
            URL(fileURLWithPath: temporary.path + "-wal"),
            URL(fileURLWithPath: temporary.path + "-shm"),
            URL(fileURLWithPath: temporary.path + "-journal"),
        ]
        defer {
            for artifact in temporaryArtifacts {
                try? fileManager.removeItem(at: artifact)
            }
        }

        try self.backUpDatabase(from: source, to: temporary)
        try self.publishWithoutReplacing(temporary, at: destination)
    }

    private static func publishWithoutReplacing(_ temporary: URL, at destination: URL) throws {
        let result = temporary.path.withCString { temporaryPath in
            destination.path.withCString { destinationPath in
                renamex_np(temporaryPath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result != 0 else { return }
        guard errno != EEXIST else { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func backUpDatabase(from source: URL, to destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        let sourceResult = sqlite3_open_v2(source.path, &sourceDatabase, SQLITE_OPEN_READONLY, nil)
        guard sourceResult == SQLITE_OK, let sourceDatabase else {
            let message = self.errorMessage(from: sourceDatabase, fallbackCode: sourceResult)
            if let sourceDatabase { sqlite3_close(sourceDatabase) }
            throw MigrationError.openSource(message)
        }

        var destinationDatabase: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destination.path,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE,
            nil
        )
        guard destinationResult == SQLITE_OK, let destinationDatabase else {
            let message = self.errorMessage(from: destinationDatabase, fallbackCode: destinationResult)
            if let destinationDatabase { sqlite3_close(destinationDatabase) }
            sqlite3_close(sourceDatabase)
            throw MigrationError.openDestination(message)
        }

        guard let backup = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            let message = self.errorMessage(from: destinationDatabase, fallbackCode: sqlite3_errcode(destinationDatabase))
            sqlite3_close(destinationDatabase)
            sqlite3_close(sourceDatabase)
            throw MigrationError.backup(message)
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let code = stepResult == SQLITE_DONE ? finishResult : stepResult
            let message = self.errorMessage(from: destinationDatabase, fallbackCode: code)
            sqlite3_close(destinationDatabase)
            sqlite3_close(sourceDatabase)
            throw MigrationError.backup(message)
        }

        // The backup copies WAL mode from the source. Switch the temporary database back to a
        // single-file journal before renaming it, so no committed pages remain in a sidecar.
        let journalResult = sqlite3_exec(destinationDatabase, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        guard journalResult == SQLITE_OK else {
            let message = self.errorMessage(from: destinationDatabase, fallbackCode: journalResult)
            sqlite3_close(destinationDatabase)
            sqlite3_close(sourceDatabase)
            throw MigrationError.backup(message)
        }

        let destinationCloseResult = sqlite3_close(destinationDatabase)
        let sourceCloseResult = sqlite3_close(sourceDatabase)
        guard destinationCloseResult == SQLITE_OK else {
            throw MigrationError.closeDestination(String(cString: sqlite3_errstr(destinationCloseResult)))
        }
        guard sourceCloseResult == SQLITE_OK else {
            throw MigrationError.closeSource(String(cString: sqlite3_errstr(sourceCloseResult)))
        }
    }

    private static func errorMessage(from database: OpaquePointer?, fallbackCode: Int32) -> String {
        if let database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return String(cString: sqlite3_errstr(fallbackCode))
    }

    private enum MigrationError: LocalizedError {
        case openSource(String)
        case openDestination(String)
        case backup(String)
        case closeSource(String)
        case closeDestination(String)

        var errorDescription: String? {
            switch self {
            case let .openSource(message): "Could not open the legacy cost database: \(message)"
            case let .openDestination(message): "Could not create the migrated cost database: \(message)"
            case let .backup(message): "Could not copy the legacy cost database: \(message)"
            case let .closeSource(message): "Could not close the legacy cost database: \(message)"
            case let .closeDestination(message): "Could not close the migrated cost database: \(message)"
            }
        }
    }
}
