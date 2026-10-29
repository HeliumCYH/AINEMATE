import Foundation

/// Turns OpenCode's own event store into pet actors.
///
/// OpenCode keeps sessions, messages, parts and todos in a SQLite database under
/// `~/.local/share/opencode`, which the desktop app and the CLI share. The turn is
/// read out of the message row the way the app's UI reads it: an assistant message
/// without a completion timestamp is still being generated.
public final class OpenCodeAdapter: AgentAdapter {
    public let source = "opencode"

    private let databasePath: String
    private let activityWindow: TimeInterval
    private let reader = SQLiteReader()

    public init(databaseURL: URL = OpenCodeAdapter.defaultDatabase(),
                activityWindow: TimeInterval? = nil) {
        self.databasePath = databaseURL.path
        self.activityWindow = activityWindow ?? Self.defaultActivityWindow
    }

    public static func defaultDatabase() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let override = ProcessInfo.processInfo.environment["AIMATE_OPENCODE_DB"] {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    public func poll(now: Date) -> [Actor] {
        guard reader.open(databasePath) else { return [] }
        return usesV2() ? pollV2(now: now) : pollV1(now: now)
    }

    /// 2.2 moved every conversation to `session_v2`/`session_message` and left the
    /// old tables frozen at the migration date. Reading the newer schema whenever
    /// it exists keeps today's desktop app visible; the v1 queries stay for stores
    /// that have not been migrated yet.
    private func usesV2() -> Bool {
        guard let newest = reader.query("select max(time_updated) as stamp from session_v2;")?
            .first?["stamp"].flatMap({ $0 }).flatMap({ Double($0) }) else { return false }
        let legacy = reader.query("select max(time_updated) as stamp from session;")?
            .first?["stamp"].flatMap { $0 }.flatMap { Double($0) }
        return legacy == nil || newest >= legacy!
    }

    private func pollV1(now: Date) -> [Actor] {
        var actors: [Actor] = []
        for row in recentSessions() {
            guard let id = row["id"].flatMap({ $0 }), !id.isEmpty else { continue }
            // A running turn writes parts more often than it writes the session
            // row, so the freshest of the two is the honest liveness stamp.
            let stamps = [row["time_updated"].flatMap { $0 }, latestPartTime(session: id)]
            let updated = Self.date(stamps) ?? .distantPast
            let reading = turnReading(session: id, todos: todoProgress(session: id))
            guard let actor = ActorRules.actor(
                source: source, id: id, foldState: reading.state, foldUpdated: updated,
                now: now, activityWindow: activityWindow,
                title: Self.label(row["title"].flatMap { $0 })
                    ?? ActorRules.directoryLabel(row["directory"].flatMap { $0 })
                        .map { "OpenCode · \($0)" }
                    ?? "OpenCode 会话",
                detail: reading.detail, pid: nil) else { continue }
            actors.append(actor)
        }
        return actors
    }

    // MARK: - Queries

    private func recentSessions() -> [[String: String?]] {
        reader.query("""
        select id, title, directory, time_updated
        from session
        where time_archived is null
        order by time_updated desc
        limit 3;
        """) ?? []
    }

    private func latestPartTime(session: String) -> String? {
        reader.query("""
        select max(time_updated) as touched from part where session_id = ?;
        """, params: [session])?.first?["touched"].flatMap { $0 }
    }

    struct MessageReading {
        var role: String?
        var created: String?
        var completed: String?
        var errorName: String?
        var errorMessage: String?
    }

    struct PartReading {
        var kind: String?
        var tool: String?
        var status: String?
    }

    private func latestMessage(session: String) -> MessageReading? {
        guard let row = reader.query("""
        select json_extract(data, '$.role') as role,
               json_extract(data, '$.time.created') as created,
               json_extract(data, '$.time.completed') as completed,
               json_extract(data, '$.error.name') as error_name,
               json_extract(data, '$.error.data.message') as error_message
        from message
        where session_id = ?
        order by time_created desc, id desc
        limit 1;
        """, params: [session])?.first else { return nil }
        return MessageReading(
            role: row["role"].flatMap { $0 },
            created: row["created"].flatMap { $0 },
            completed: row["completed"].flatMap { $0 },
            errorName: row["error_name"].flatMap { $0 },
            errorMessage: row["error_message"].flatMap { $0 })
    }

    private func latestPart(session: String) -> PartReading? {
        guard let row = reader.query("""
        select json_extract(data, '$.type') as kind,
               json_extract(data, '$.tool') as tool,
               json_extract(data, '$.state.status') as status
        from part
        where session_id = ?
        order by time_created desc, id desc
        limit 1;
        """, params: [session])?.first else { return nil }
        return PartReading(kind: row["kind"].flatMap { $0 }, tool: row["tool"].flatMap { $0 },
                           status: row["status"].flatMap { $0 })
    }

    private func todoProgress(session: String) -> (done: Int, total: Int)? {
        guard let rows = reader.query("""
        select status, count(*) as n from todo where session_id = ? group by status;
        """, params: [session]) else { return nil }
        var done = 0, total = 0
        for row in rows {
            guard let count = Int(row["n"].flatMap { $0 } ?? "") else { continue }
            total += count
            if Self.isDone(row["status"].flatMap { $0 }) { done += count }
        }
        return total > 0 ? (done, total) : nil
    }

    // MARK: - Queries (schema 2)

    private func pollV2(now: Date) -> [Actor] {
        var actors: [Actor] = []
        for row in recentV2Sessions() {
            guard let id = row["id"].flatMap({ $0 }), !id.isEmpty else { continue }
            let stamps = [row["time_updated"].flatMap { $0 }, latestV2MessageTime(session: id)]
            let updated = Self.date(stamps) ?? .distantPast
            let reading = turnReadingV2(session: id, todos: todoProgress(session: id), now: now)
            guard let actor = ActorRules.actor(
                source: source, id: id, foldState: reading.state, foldUpdated: updated,
                now: now, activityWindow: activityWindow,
                title: Self.label(row["title"].flatMap { $0 })
                    ?? ActorRules.directoryLabel(row["directory"].flatMap { $0 })
                        .map { "OpenCode · \($0)" }
                    ?? "OpenCode 会话",
                detail: reading.detail, pid: nil,
                startedAt: Self.startDate(row["time_created"].flatMap { $0 })) else { continue }
            actors.append(actor)
        }
        return actors
    }

    private func recentV2Sessions() -> [[String: String?]] {
        reader.query("""
        select id, title, directory, time_updated, time_created
        from session_v2
        where time_archived is null
        order by time_updated desc
        limit 3;
        """) ?? []
    }

    /// Streaming rewrites the assistant row's `time_updated`, so the message table
    /// alone proves a turn is still moving.
    private func latestV2MessageTime(session: String) -> String? {
        reader.query("""
        select max(time_updated) as touched from session_message where session_id = ?;
        """, params: [session])?.first?["touched"].flatMap { $0 }
    }

    struct MessageV2: Decodable {
        var time: Time?
        var error: Failure?
        var content: [Part]?

        struct Time: Decodable {
            var created: Int64?
            var completed: Int64?
        }

        /// 2.2's errors carry `type` (`aborted`, `provider.error`) where schema 1
        /// used `name`.
        struct Failure: Decodable {
            var type: String?
            var message: String?
        }

        struct Part: Decodable {
            var type: String?
            var name: String?
            var state: Status?

            struct Status: Decodable { var status: String? }
        }
    }

    /// The newest row that says something about the turn. Compaction, synthetic
    /// and system rows are bookkeeping and would only hide the real message.
    private func latestV2Message(session: String) -> (type: String, seq: Int, message: MessageV2)? {
        guard let row = reader.query("""
        select type, seq, data from session_message
        where session_id = ? and type in ('user', 'assistant', 'idle')
        order by seq desc
        limit 1;
        """, params: [session])?.first,
            let type = row["type"].flatMap({ $0 }),
            let seq = row["seq"].flatMap({ $0 }).flatMap({ Int($0) }),
            let raw = row["data"].flatMap({ $0 }), let json = raw.data(using: .utf8),
            let message = try? JSONDecoder().decode(MessageV2.self, from: json)
        else { return nil }
        return (type, seq, message)
    }

    /// How long a completed response without an `idle` row stays "running". A
    /// model reply finishing is not the turn finishing: tools run after it and
    /// the next step follows a second or two later, so treating the completion
    /// stamp alone as done made the pet flash 待检查 between every step.
    static let turnSettleGrace: TimeInterval = 15

    private func turnReadingV2(
        session: String, todos: (done: Int, total: Int)?, now: Date
    ) -> TurnReading {
        guard let reading = latestV2Message(session: session) else {
            return TurnReading(state: todos == nil ? .idle : .running, detail: Self.todoText(todos))
        }
        let message = reading.message
        switch reading.type {
        case "assistant":
            if let error = message.error {
                if Self.isAbort(error.type, error.message) {
                    return TurnReading(state: .idle, detail: nil)
                }
                return TurnReading(
                    state: .failed, detail: Self.errorMessage(error.message ?? error.type))
            }
            // Tools execute after the response's `completed` stamp is written, so
            // a live tool outranks it: the turn is still moving.
            if let tool = Self.toolText(message.content) {
                return TurnReading(state: .running, detail: tool)
            }
            guard let completed = message.time?.completed else {
                return TurnReading(state: .running, detail: Self.todoText(todos))
            }
            let ended = Date(timeIntervalSince1970: Double(completed) / 1000)
            guard now.timeIntervalSince(ended) >= Self.turnSettleGrace else {
                return TurnReading(state: .running, detail: "正在回复")
            }
            return TurnReading(state: .review, detail: "已完成，等你确认")
        case "idle":
            // 2.2 writes this row when the turn really settles.
            return TurnReading(
                state: .review,
                detail: Self.settledDetail(
                    started: latestUserStart(session: session, before: reading.seq),
                    idle: message.time?.created))
        default:
            return TurnReading(state: .running, detail: Self.todoText(todos) ?? "已提交，等待回复")
        }
    }

    /// The user message that opened the settled turn, in epoch milliseconds.
    private func latestUserStart(session: String, before seq: Int) -> Int64? {
        reader.query("""
        select json_extract(data, '$.time.created') as started
        from session_message
        where session_id = ? and type = 'user' and seq < ?
        order by seq desc
        limit 1;
        """, params: [session, seq])?.first?["started"].flatMap { $0 }.flatMap { Int64($0) }
    }

    static func settledDetail(started: Int64?, idle: Int64?) -> String {
        guard let started, let idle, idle > started else { return "已完成，等你确认" }
        return "已完成，用时 \(ActorRules.humanDuration(Int(idle - started)))"
    }

    /// 2.2 keeps tool calls inline in the assistant message; only a non-terminal
    /// status means work is still in flight.
    static func toolText(_ content: [MessageV2.Part]?) -> String? {
        guard let part = content?.last(where: { $0.type == "tool" && isLive($0.state?.status) })
        else { return nil }
        guard let name = part.name, !name.isEmpty else { return "正在调用工具" }
        return "正在使用 \(name)"
    }

    static func isLive(_ status: String?) -> Bool {
        guard let status else { return false }
        // `streaming` is 2.2's state while the model is still emitting the call.
        return ["pending", "streaming", "running", "call"].contains(status.lowercased())
    }

    static func isAbort(_ type: String?, _ message: String?) -> Bool {
        if let type, type.lowercased().contains("abort") { return true }
        return message?.lowercased().contains("aborted") == true
    }

    static let defaultActivityWindow: TimeInterval = 900

    static func isDone(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["completed", "complete", "done", "cancelled"].contains(status.lowercased())
    }

    // MARK: - Reading

    struct TurnReading {
        let state: PetState
        let detail: String?
    }

    private func turnReading(session: String, todos: (done: Int, total: Int)?) -> TurnReading {
        guard let message = latestMessage(session: session) else {
            return TurnReading(state: todos == nil ? .idle : .running, detail: Self.todoText(todos))
        }
        if let name = message.errorName, !name.isEmpty {
            // "MessageAbortedError" is the user pressing stop, not a broken run;
            // the pet must not flash danger for a cancel.
            if name.contains("Aborted") {
                return TurnReading(state: .idle, detail: nil)
            }
            return TurnReading(state: .failed, detail: Self.errorMessage(message.errorMessage))
        }
        let toolText = Self.toolText(latestPart(session: session))
        switch (message.role, message.completed) {
        case ("assistant", nil):
            return TurnReading(state: .running, detail: toolText ?? Self.todoText(todos))
        case ("assistant", let completed?):
            let elapsed = message.created.flatMap { Self.elapsed(from: $0, to: completed) }
            return TurnReading(
                state: .review,
                detail: elapsed.map { "已完成，用时 \(ActorRules.humanDuration($0))" } ?? "已完成，等你确认")
        case ("user", _):
            return TurnReading(state: .running, detail: toolText ?? "已提交，等待回复")
        default:
            return TurnReading(state: .review, detail: Self.todoText(todos))
        }
    }

    /// OpenCode marks a tool call in flight with a non-terminal part status; the
    /// terminal ones must not be shown as work still happening.
    static func toolText(_ part: PartReading?) -> String? {
        guard let part, part.kind == "tool", let status = part.status,
              ["pending", "running", "call"].contains(status) else { return nil }
        guard let tool = part.tool, !tool.isEmpty else { return "正在调用工具" }
        return "正在使用 \(tool)"
    }

    static func todoText(_ todos: (done: Int, total: Int)?) -> String? {
        guard let todos else { return nil }
        return "任务 \(todos.done)/\(todos.total) 项完成"
    }

    /// Some providers wrap the readable text in a JSON envelope
    /// (`{"message":"..."}`), which would otherwise fill the card with braces.
    static func errorMessage(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "运行出错" }
        if text.hasPrefix("{"), let data = text.data(using: .utf8),
           let tree = try? JSONDecoder().decode(JSONValue.self, from: data),
           let inner = tree.displayText, !inner.isEmpty {
            return ActorRules.trim(inner)
        }
        return ActorRules.trim(text)
    }

    static func elapsed(from: String, to: String) -> Int? {
        guard let start = Double(from), let end = Double(to) else { return nil }
        return Int(end - start)
    }

    /// OpenCode writes epoch milliseconds; a missing stamp is not a date.
    static func date(_ millisecondStamps: [String?]) -> Date? {
        guard let latest = millisecondStamps.compactMap({ Double($0 ?? "") }).max() else { return nil }
        return Date(timeIntervalSince1970: latest / 1000)
    }

    /// The session row's creation stamp, which the card uses for row order.
    static func startDate(_ milliseconds: String?) -> Date? {
        guard let milliseconds, let value = Double(milliseconds) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    static func label(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return ActorRules.trim(text)
    }
}
