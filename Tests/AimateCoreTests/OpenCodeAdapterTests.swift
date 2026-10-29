import Foundation
import SQLite3
import Testing

@testable import AimateCore

/// Drives the OpenCode adapter against a throwaway database built with the real
/// table and JSON shapes read out of `~/.local/share/opencode/opencode.db`, so the
/// turn inference is verified without touching the user's own store.
struct OpenCodeAdapterTests {
    private static let session = "ses_e7d813109ffe20Ow3gGMw1fhr0"
    private static let now = Date()

    /// Opens (creating the file) a fixture database, runs the setup, and returns
    /// its URL. Only the columns the adapter selects are created.
    private func database(_ setup: (OpaquePointer?) throws -> Void) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-opencode-\(UUID().uuidString).db")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw OpenCodeFixtureFailure.cannotCreate(url.path)
        }
        defer { sqlite3_close_v2(handle) }

        Self.execute(handle, """
        create table session (id text primary key, directory text not null, title text not null,
            time_updated integer not null, time_archived integer);
        create table message (id text primary key, session_id text not null,
            time_created integer not null, data text not null);
        create table part (id text primary key, session_id text not null,
            time_created integer not null, time_updated integer not null, data text not null);
        create table todo (session_id text not null, status text not null, position integer not null,
            primary key (session_id, position));
        """)
        try setup(handle)
        return url
    }

    enum OpenCodeFixtureFailure: Error { case cannotCreate(String) }

    private static func execute(_ handle: OpaquePointer?, _ sql: String) {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            Issue.record("fixture SQL failed: \(text)")
            return
        }
        sqlite3_free(message)
    }

    private static func milliseconds(_ offset: TimeInterval) -> Int64 {
        Int64(Self.now.addingTimeInterval(offset).timeIntervalSince1970 * 1000)
    }

    private static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    private static func sessionRow(
        id: String = session, title: String = "Mac软件mole逆向工程",
        directory: String = "/Users/me/REA_project/mole", updated: TimeInterval = -5,
        archived: Bool = false
    ) -> String {
        "insert into session values ('\(id)', '\(quote(directory))', '\(quote(title))', "
            + "\(milliseconds(updated))" + (archived ? ", \(milliseconds(0))" : ", null") + ");"
    }

    private static func messageRow(
        role: String, created: TimeInterval, completed: TimeInterval?,
        errorName: String? = nil, errorMessage: String? = nil,
        id: String = "msg_1827ecf56001fhsX44luzUCiQa"
    ) -> String {
        var time: [String: Any] = ["created": milliseconds(created)]
        if let completed { time["completed"] = milliseconds(completed) }
        var data: [String: Any] = ["role": role, "time": time]
        if let errorName {
            data["error"] = ["name": errorName, "data": ["message": errorMessage ?? ""]]
        }
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
            encoding: .utf8)!
        return "insert into message values ('\(id)', '\(session)', \(milliseconds(created)), "
            + "'\(quote(json))');"
    }

    private static func partRow(tool: String, status: String, updated: TimeInterval) -> String {
        let json = #"{"type":"tool","tool":"\#(tool)","state":{"status":"\#(status)"}}"#
        return "insert into part values ('prt_1', '\(session)', \(milliseconds(updated - 1)), "
            + "\(milliseconds(updated)), '\(quote(json))');"
    }

    private func actor(
        _ statements: [String], activityWindow: TimeInterval = 900
    ) throws -> Actor? {
        let url = try database { handle in
            for statement in statements { Self.execute(handle, statement) }
        }
        return OpenCodeAdapter(databaseURL: url, activityWindow: activityWindow)
            .poll(now: Self.now).first
    }

    /// 2.2's store: `session_v2` plus `session_message`, with the turn, tool calls
    /// and errors all living inside the message's `data` JSON. Only the columns
    /// the adapter reads are created.
    private func databaseV2(_ setup: (OpaquePointer?) throws -> Void) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-opencode-v2-\(UUID().uuidString).db")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw OpenCodeFixtureFailure.cannotCreate(url.path)
        }
        defer { sqlite3_close_v2(handle) }

        Self.execute(handle, """
        create table session_v2 (id text primary key, directory text not null, title text,
            time_created integer not null, time_updated integer not null, time_archived integer);
        create table session_message (id text primary key, session_id text not null,
            type text not null, seq integer not null, time_created integer not null,
            time_updated integer not null, data text not null);
        create table todo (session_id text not null, status text not null, position integer not null,
            primary key (session_id, position));
        """)
        try setup(handle)
        return url
    }

    private func actorV2(
        _ statements: [String], activityWindow: TimeInterval = 900
    ) throws -> Actor? {
        let url = try databaseV2 { handle in
            for statement in statements { Self.execute(handle, statement) }
        }
        return OpenCodeAdapter(databaseURL: url, activityWindow: activityWindow)
            .poll(now: Self.now).first
    }

    private static func v2Session(
        id: String = session, title: String? = "Metis 系统占用情况",
        directory: String = "/Users/me/默认项目", updated: TimeInterval = -5,
        archived: Bool = false
    ) -> String {
        "insert into session_v2 values ('\(id)', '\(quote(directory))', "
            + (title.map { "'\(quote($0))'" } ?? "null") + ", "
            + "\(milliseconds(updated - 3_600)), \(milliseconds(updated))"
            + (archived ? ", \(milliseconds(0))" : ", null") + ");"
    }

    private static func v2Message(
        _ type: String, seq: Int, updated: TimeInterval, data: [String: Any]
    ) -> String {
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
            encoding: .utf8)!
        return "insert into session_message values ('msg_v2_\(seq)', '\(session)', '\(type)', "
            + "\(seq), \(milliseconds(updated)), \(milliseconds(updated)), '\(quote(json))');"
    }

    private static func assistantData(
        created: TimeInterval, completed: TimeInterval?,
        tools: [(name: String, status: String)] = [],
        error: (type: String, message: String)? = nil
    ) -> [String: Any] {
        var time: [String: Any] = ["created": milliseconds(created)]
        if let completed { time["completed"] = milliseconds(completed) }
        var data: [String: Any] = [
            "time": time,
            "content": tools.map {
                ["type": "tool", "name": $0.name, "state": ["status": $0.status]] as [String: Any]
            },
        ]
        if let error { data["error"] = ["type": error.type, "message": error.message] }
        return data
    }

    private static func userData(text: String, created: TimeInterval) -> [String: Any] {
        ["text": text, "time": ["created": milliseconds(created)]]
    }

    private static func idleData(created: TimeInterval, outcome: String = "succeeded") -> [String: Any] {
        ["time": ["created": milliseconds(created)], "outcome": outcome]
    }

    @Test("an assistant message with no completion is still generating")
    func running() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
        ])
        #expect(result?.state == .running)
        #expect(result?.source == "opencode")
        #expect(result?.thread == Self.session)
        #expect(result?.title == "Mac软件mole逆向工程")
    }

    @Test("an in-flight tool call names the tool")
    func toolInFlight() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
            Self.partRow(tool: "bash", status: "running", updated: -2),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在使用 bash")
    }

    @Test("a completed tool call is not reported as work")
    func toolSettled() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
            Self.partRow(tool: "bash", status: "completed", updated: -2),
        ])
        #expect(result?.detail == nil)
    }

    @Test("a completed turn reads as review with its duration")
    func review() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -65, completed: -0.2),
        ])
        #expect(result?.state == .review)
        #expect(result?.detail?.contains("已完成，用时") == true)
    }

    @Test("the 426 free-model refusal reads as failed")
    func failed() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -10, completed: -5,
                            errorName: "APIError",
                            errorMessage: "This version of OpenCode Desktop no longer supports free models."),
        ])
        #expect(result?.state == .failed)
        #expect(result?.detail?.hasPrefix("This version of OpenCode Desktop") == true)
    }

    @Test("a prompt awaiting its first reply reads as running")
    func submitted() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "user", created: -3, completed: nil,
                            id: "msg_1827ecf34001GomwEPVroAt03P"),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "已提交，等待回复")
    }

    @Test("todos are counted into the detail")
    func todos() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
            "insert into todo values ('\(Self.session)', 'completed', 1);",
            "insert into todo values ('\(Self.session)', 'in_progress', 2);",
            "insert into todo values ('\(Self.session)', 'pending', 3);",
        ])
        #expect(result?.detail == "任务 1/3 项完成")
    }

    @Test("a user abort is not reported as a failure")
    func abortIsNotFailure() throws {
        // Observed in the real store: stopping a run writes MessageAbortedError.
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -20, completed: -5,
                            errorName: "MessageAbortedError", errorMessage: "Aborted"),
        ])
        #expect(result == nil)
    }

    @Test("a json-wrapped provider error is read down to its text")
    func wrappedError() throws {
        let result = try actor([
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -20, completed: -5,
                            errorName: "UnknownError",
                            errorMessage: #"{"message":"context length too small"}"#),
        ])
        #expect(result?.state == .failed)
        #expect(result?.detail == "context length too small")
    }

    @Test("an archived session is not shown")
    func archived() throws {
        let result = try actor([
            Self.sessionRow(archived: true),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
        ])
        #expect(result == nil)
    }

    @Test("a session older than the activity window is dropped")
    func stale() throws {
        let result = try actor([
            Self.sessionRow(updated: -4_000),
            Self.messageRow(role: "assistant", created: -4_000, completed: -3_990),
        ])
        #expect(result == nil)
    }

    @Test("a part timestamp keeps a live turn alive")
    func partRefreshesLiveness() throws {
        // The session row lags; the newest part is what proves the turn is moving.
        let result = try actor([
            Self.sessionRow(updated: -300),
            Self.messageRow(role: "assistant", created: -300, completed: nil),
            Self.partRow(tool: "read", status: "running", updated: -10),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在使用 read")
    }

    @Test("schema 2: an assistant message with no completion is still generating")
    func v2Running() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("user", seq: 1, updated: -40,
                           data: Self.userData(text: "检查系统占用", created: -40)),
            Self.v2Message("assistant", seq: 2, updated: -30,
                           data: Self.assistantData(created: -30, completed: nil)),
        ])
        #expect(result?.state == .running)
        #expect(result?.source == "opencode")
        #expect(result?.thread == Self.session)
        #expect(result?.title == "Metis 系统占用情况")
        // The fixture starts every session an hour before its update; the store
        // keeps whole milliseconds, so compare with a millisecond of slack.
        let started = try #require(result?.startedAt)
        #expect(abs(started.timeIntervalSince(Self.now) + 3_605) < 0.002)
    }

    @Test("schema 2: the in-flight tool is named even with a settled one after it")
    func v2ToolInFlight() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -2, data: Self.assistantData(
                created: -30, completed: nil,
                tools: [("shell", "running"), ("read", "completed")])),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在使用 shell")
    }

    @Test("schema 2: settled tools are not reported as work")
    func v2ToolSettled() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -2, data: Self.assistantData(
                created: -30, completed: nil, tools: [("shell", "completed")])),
        ])
        #expect(result?.detail == nil)
    }

    @Test("schema 2: a completed turn reads as review with its duration")
    func v2Review() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -20, data: Self.assistantData(
                created: -80, completed: -20)),
        ])
        #expect(result?.state == .review)
        #expect(result?.detail == "已完成，等你确认")
    }

    @Test("schema 2: a response that just completed is not the turn finishing")
    func v2BetweenStepsIsRunning() throws {
        // Observed live: an assistant row gets `completed` while its tools still
        // run and the next step follows seconds later. That gap must stay running.
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -1, data: Self.assistantData(
                created: -5, completed: -1)),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在回复")
    }

    @Test("schema 2: a live tool outranks the response's completion stamp")
    func v2CompletedWithLiveTool() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -1, data: Self.assistantData(
                created: -6, completed: -1, tools: [("shell", "running")])),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在使用 shell")
    }

    @Test("schema 2: a tool whose call is still streaming is named")
    func v2StreamingTool() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -2, data: Self.assistantData(
                created: -4, completed: nil, tools: [("shell", "streaming")])),
        ])
        #expect(result?.detail == "正在使用 shell")
    }

    @Test("schema 2: a provider error reads as failed")
    func v2Failed() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -5, data: Self.assistantData(
                created: -10, completed: -5,
                error: ("provider.error",
                        "This version of OpenCode Desktop no longer supports free models."))),
        ])
        #expect(result?.state == .failed)
        #expect(result?.detail?.hasPrefix("This version of OpenCode Desktop") == true)
    }

    @Test("schema 2: a user abort is not reported as a failure")
    func v2Abort() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -5, data: Self.assistantData(
                created: -20, completed: -5, error: ("aborted", "Aborted"))),
        ])
        #expect(result == nil)
    }

    @Test("schema 2: the idle row settles the session as review")
    func v2Idle() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("user", seq: 0, updated: -20,
                           data: Self.userData(text: "检查系统占用", created: -20)),
            Self.v2Message("assistant", seq: 1, updated: -9, data: Self.assistantData(
                created: -9, completed: -8)),
            Self.v2Message("idle", seq: 2, updated: -8,
                           data: Self.idleData(created: -8)),
        ])
        #expect(result?.state == .review)
        #expect(result?.detail == "已完成，用时 12 秒")
    }

    @Test("schema 2: bookkeeping rows do not hide the turn")
    func v2Bookkeeping() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -20, data: Self.assistantData(
                created: -30, completed: nil, tools: [("shell", "running")])),
            Self.v2Message("compaction", seq: 2, updated: -5, data: ["summary": "…"]),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "正在使用 shell")
    }

    @Test("schema 2: todos are counted into the detail")
    func v2Todos() throws {
        let result = try actorV2([
            Self.v2Session(),
            Self.v2Message("assistant", seq: 1, updated: -30,
                           data: Self.assistantData(created: -30, completed: nil)),
            "insert into todo values ('\(Self.session)', 'completed', 1);",
            "insert into todo values ('\(Self.session)', 'in_progress', 2);",
            "insert into todo values ('\(Self.session)', 'pending', 3);",
        ])
        #expect(result?.detail == "任务 1/3 项完成")
    }

    @Test("schema 2: an archived session is not shown")
    func v2Archived() throws {
        let result = try actorV2([
            Self.v2Session(archived: true),
            Self.v2Message("assistant", seq: 1, updated: -30,
                           data: Self.assistantData(created: -30, completed: nil)),
        ])
        #expect(result == nil)
    }

    @Test("schema 2: a session older than the activity window is dropped")
    func v2Stale() throws {
        let result = try actorV2([
            Self.v2Session(updated: -4_000),
            Self.v2Message("assistant", seq: 1, updated: -4_000,
                           data: Self.assistantData(created: -4_000, completed: -3_990)),
        ])
        #expect(result == nil)
    }

    @Test("an empty schema-2 table keeps the legacy reader working")
    func v2EmptyFallsBack() throws {
        let result = try actor([
            "create table session_v2 (id text primary key, directory text not null, title text, "
                + "time_created integer not null, time_updated integer not null, time_archived integer);",
            Self.sessionRow(),
            Self.messageRow(role: "assistant", created: -30, completed: nil),
        ])
        #expect(result?.state == .running)
    }

    @Test("a missing database is not an error")
    func missingDatabase() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-opencode-absent-\(UUID().uuidString).db")
        #expect(OpenCodeAdapter(databaseURL: absent).poll(now: Date()).isEmpty)
    }

    @Test("a session with no messages shows nothing")
    func emptySession() throws {
        #expect(try actor([Self.sessionRow()]) == nil)
    }
}
