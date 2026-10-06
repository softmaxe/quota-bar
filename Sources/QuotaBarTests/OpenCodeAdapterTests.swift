import QuotaBarCore
import Foundation
import SQLite3

/// OpenCode database rows in, observed requests out, with no recorder.
enum OpenCodeAdapterTests {
    static func run() {
        Self.stepFinishesFromOpenAIBecomeRequests()
        Self.unexpectedSchemaIsAnError()
        Self.fastComesFromTheTierOrTheToggle()
        Self.signInIsCheckedBeforeTheDatabase()
    }

    /// Each OpenAI `step-finish` part is one request keyed by its part id. Reasoning is output,
    /// and other providers' usage is not OpenAI's to record.
    private static func stepFinishesFromOpenAIBecomeRequests() {
        let root = Self.temporaryRoot("requests")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let db = OpenCodeFixtureDatabase(at: root) else { return }
        db.stepFinish("part-1", created: 1_788_264_000_000, model: "gpt-5.6-luna", input: 10, output: 20, reasoning: 30, cacheRead: 40, cacheWrite: 50)
        db.stepFinish("other", created: 1_788_264_000_000, provider: "openrouter", model: "gpt-5.6-luna", input: 10)
        db.stepFinish("empty", created: 1_788_264_000_000, model: "gpt-5.6-luna")
        db.close()

        let requests = Self.requests(root: root)
        Harness.expectEqual(requests?.count, 1, "only OpenAI step-finish parts with tokens are requests")
        Harness.expectEqual(
            requests?.first,
            ObservedRequest(
                key: "part-1",
                timestamp: Date(timeIntervalSince1970: 1_788_264_000),
                model: "gpt-5.6-luna",
                tokens: TokenTotals(input: 10, output: 50, cacheWrite: 50, cacheRead: 40),
                isFast: false
            ),
            "a step-finish part maps its tokens, millisecond time, and raw model"
        )
    }

    /// A database whose tables lack the columns the query needs is a newer or broken format,
    /// not an empty one, so reading it fails rather than recording nothing.
    private static func unexpectedSchemaIsAnError() {
        let root = Self.temporaryRoot("schema")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let db = OpenCodeFixtureDatabase(at: root, partColumns: "id TEXT PRIMARY KEY, data TEXT NOT NULL") else { return }
        db.close()

        Harness.expectThrows("an OpenCode part table without message_id") {
            _ = try OpenCodeAdapter(env: isolatedEnvironment(root: root)).requests()
        }
    }

    /// Fast comes from an explicit tier on the message, else from part metadata, else from the
    /// last "Fast mode is now ON./OFF." toggle the user sent before the request.
    private static func fastComesFromTheTierOrTheToggle() {
        let root = Self.temporaryRoot("fast")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let db = OpenCodeFixtureDatabase(at: root) else { return }
        let start: Int64 = 1_788_264_000_000
        db.stepFinish("standard", created: start, model: "gpt-5.6-sol", input: 1)
        db.stepFinish("message-tier", created: start + 1, model: "gpt-5.6-sol", input: 1, serviceTier: "priority")
        db.stepFinish("metadata-tier", created: start + 2, model: "gpt-5.6-sol", input: 1, metadataTier: "priority")
        db.fastToggle("on", created: start + 3, on: true)
        db.stepFinish("toggled-on", created: start + 4, model: "gpt-5.6-sol", input: 1)
        db.stepFinish("explicit-default", created: start + 5, model: "gpt-5.6-sol", input: 1, serviceTier: "default")
        db.fastToggle("off", created: start + 6, on: false)
        db.stepFinish("toggled-off", created: start + 7, model: "gpt-5.6-sol", input: 1)
        db.close()

        let fast = Dictionary(
            (Self.requests(root: root) ?? []).map { ($0.key ?? "", $0.isFast) },
            uniquingKeysWith: { first, _ in first }
        )
        Harness.expectEqual(fast["standard"], false, "a request before any toggle is Standard")
        Harness.expectEqual(fast["message-tier"], true, "a message whose service tier is `priority` is Fast")
        Harness.expectEqual(fast["metadata-tier"], true, "part metadata whose service tier is `priority` is Fast")
        Harness.expectEqual(fast["toggled-on"], true, "a request after Fast mode is turned on is Fast")
        Harness.expectEqual(fast["explicit-default"], false, "an explicit tier outranks the toggle")
        Harness.expectEqual(fast["toggled-off"], false, "a request after Fast mode is turned off is Standard")
    }

    /// A sign-in that cannot be checked fails the survey as `auth` before the database is
    /// opened, so it is the reason reported even when the database is unreadable too.
    private static func signInIsCheckedBeforeTheDatabase() {
        let root = Self.temporaryRoot("auth-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("opencode")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not a database".utf8).write(to: directory.appendingPathComponent("opencode.db"))
        try? #"{"openai":null}"#.write(to: directory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let failedOnAuth: Bool
        if case .failed(.auth) = OpenCodeAdapter(env: isolatedEnvironment(root: root)).survey() {
            failedOnAuth = true
        } else {
            failedOnAuth = false
        }
        Harness.expect(failedOnAuth, "an uncheckable sign-in is reported before an unreadable database")
    }

    private static func requests(root: URL) -> [ObservedRequest]? {
        do {
            return try OpenCodeAdapter(env: isolatedEnvironment(root: root)).requests()
        } catch {
            Harness.expect(false, "reading the OpenCode fixture threw: \(error)")
            return nil
        }
    }

    private static func temporaryRoot(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-opencode-adapter-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        return root
    }
}

/// A fake OpenCode database at `<root>/opencode/opencode.db`, where `isolatedEnvironment(root:)`
/// points OpenCode, written the way OpenCode stores messages and their parts.
final class OpenCodeFixtureDatabase {
    let url: URL
    private var db: OpaquePointer?

    init?(at root: URL, partColumns: String = "id TEXT PRIMARY KEY, message_id TEXT NOT NULL, data TEXT NOT NULL") {
        let directory = root.appendingPathComponent("opencode")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("opencode.db")
        guard sqlite3_open(self.url.path, &self.db) == SQLITE_OK else {
            Harness.expect(false, "OpenCode fixture database opens")
            sqlite3_close(self.db)
            return nil
        }
        sqlite3_exec(self.db, "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL)", nil, nil, nil)
        sqlite3_exec(self.db, "CREATE TABLE part (\(partColumns))", nil, nil, nil)
    }

    deinit { self.close() }

    func close() {
        sqlite3_close(self.db)
        self.db = nil
    }

    /// An assistant message with one `step-finish` part carrying its tokens.
    func stepFinish(
        _ id: String,
        created: Int64,
        provider: String = "openai",
        model: String,
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        serviceTier: String? = nil,
        metadataTier: String? = nil
    ) {
        let tier = serviceTier.map { #","serviceTier":"\#($0)""# } ?? ""
        self.insert("message", id: "message-\(id)", data: #"{"time":{"created":\#(created)},"role":"assistant","providerID":"\#(provider)","modelID":"\#(model)"\#(tier)}"#)
        self.insert(
            "part",
            id: id,
            messageID: "message-\(id)",
            data: #"{"type":"step-finish","tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":\#(cacheRead),"write":\#(cacheWrite)}}}"#
        )
        if let metadataTier {
            self.insert(
                "part",
                id: "text-\(id)",
                messageID: "message-\(id)",
                data: #"{"type":"text","text":"","metadata":{"openai":{"serviceTier":"\#(metadataTier)"}}}"#
            )
        }
    }

    /// The ignored user message the opencodex-fast plugin writes when Fast mode is toggled.
    func fastToggle(_ id: String, created: Int64, on: Bool) {
        self.insert("message", id: "toggle-\(id)", data: #"{"time":{"created":\#(created)},"role":"user"}"#)
        self.insert(
            "part",
            id: "toggle-text-\(id)",
            messageID: "toggle-\(id)",
            data: #"{"type":"text","text":"Fast mode is now \#(on ? "ON" : "OFF").","ignored":true}"#
        )
    }

    func execute(_ sql: String) {
        sqlite3_exec(self.db, sql, nil, nil, nil)
    }

    private func insert(_ table: String, id: String, messageID: String? = nil, data: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        let sql = messageID == nil
            ? "INSERT INTO \(table) (id, data) VALUES (?, ?)"
            : "INSERT INTO \(table) (id, message_id, data) VALUES (?, ?, ?)"
        sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        if let messageID {
            sqlite3_bind_text(stmt, 2, messageID, -1, transient)
            sqlite3_bind_text(stmt, 3, data, -1, transient)
        } else {
            sqlite3_bind_text(stmt, 2, data, -1, transient)
        }
        sqlite3_step(stmt)
    }
}
