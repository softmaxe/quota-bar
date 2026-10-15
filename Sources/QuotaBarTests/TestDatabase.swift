import Foundation
import SQLite3

/// A raw SQLite connection for what tests do outside the code under test: seeding rows, writing
/// legacy or broken schemas, holding locks, and checking what production code stored.
final class TestDatabase {
    let url: URL
    private var db: OpaquePointer?

    init(_ url: URL, readOnly: Bool = false) throws {
        self.url = url
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &self.db, flags, nil) == SQLITE_OK else {
            let message = self.lastError
            self.close()
            throw TestDatabaseError.sqlite("Could not open \(url.lastPathComponent): \(message)")
        }
    }

    deinit { self.close() }

    func close() {
        if let db { sqlite3_close(db) }
        self.db = nil
    }

    /// Runs `sql`, which may hold several statements. With bindings it must be one statement,
    /// and each `?` takes the next value, `nil` binding NULL.
    func exec(_ sql: String, _ bindings: String?...) throws {
        guard !bindings.isEmpty else {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(self.db, sql, nil, nil, &message) == SQLITE_OK else {
                let error = message.map { String(cString: $0) } ?? self.lastError
                sqlite3_free(message)
                throw TestDatabaseError.sqlite(error)
            }
            return
        }
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestDatabaseError.sqlite(self.lastError) }
    }

    /// The first column of the first row `sql` returns.
    func scalarInt(_ sql: String) throws -> Int {
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestDatabaseError.sqlite(self.lastError) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TestDatabaseError.sqlite(self.lastError)
        }
        return statement
    }

    private var lastError: String {
        self.db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }
}

enum TestDatabaseError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .sqlite(message): "SQLite test database failed: \(message)"
        }
    }
}
