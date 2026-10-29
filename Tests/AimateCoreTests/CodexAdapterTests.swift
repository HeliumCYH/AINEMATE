import Foundation
import Testing

@testable import AimateCore

/// Drives the Codex adapter with synthetic rollouts shaped like the real
/// `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl` file on this machine, so
/// the mapping is verified against the event names that file actually contains.
struct CodexAdapterTests {
    private static let uuid = "019f54bc-a5d4-7300-80e4-218022192fa9"
    private static let fileName = "rollout-2026-07-12T13-11-17-\(uuid).jsonl"

    /// Writes `<root>/sessions/<YYYY>/<MM>/<DD>/<fileName>` with records one second
    /// apart, the last one `shift` seconds before now.
    private func writeRollout(
        _ records: [[String: Any]], shift: TimeInterval = 0, root: URL? = nil, day: String? = nil
    ) throws -> URL {
        let base = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-codex-\(UUID().uuidString)", isDirectory: true)
        let day = base.appendingPathComponent("sessions").appendingPathComponent(
            day ?? Self.dayPath(for: Date().addingTimeInterval(shift)), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent(Self.fileName)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let baseTime = Date().addingTimeInterval(shift - Double(records.count))

        var lines: [String] = []
        for (index, record) in records.enumerated() {
            var envelope: [String: Any] = [
                "timestamp": formatter.string(from: baseTime.addingTimeInterval(TimeInterval(index))),
            ]
            for (key, value) in record { envelope[key] = value }
            lines.append(String(
                data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return base
    }

    /// The real store groups rollouts by the local date they started on, and the
    /// adapter only descends into the days it derives from `now`.
    private static func dayPath(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d", parts.year ?? 0)
            + "/" + String(format: "%02d", parts.month ?? 0)
            + "/" + String(format: "%02d", parts.day ?? 0)
    }

    private static func meta(cwd: String = "/Users/me/Documents/Codex/2026-07-12/wo") -> [String: Any] {
        ["type": "session_meta", "payload": [
            "session_id": uuid, "cwd": cwd, "originator": "Codex Desktop", "source": "vscode",
        ]]
    }

    private static func event(_ name: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["type": name]
        for (key, value) in fields { payload[key] = value }
        return ["type": "event_msg", "payload": payload]
    }

    private func actor(
        after records: [[String: Any]], shift: TimeInterval = 0, day: String? = nil
    ) throws -> Actor? {
        let root = try writeRollout(records, shift: shift, day: day)
        return CodexAdapter(codexRoot: root).poll(now: Date()).first
    }

    @Test("a thread that started days ago and is still writing is discovered")
    func longRunningThread() throws {
        // Appending to a rollout never bumps its directory's mtime, so pruning the
        // tree by directory date would silently drop yesterday's live turn.
        let result = try actor(after: [
            Self.meta(), Self.event("task_started"), Self.event("agent_reasoning"),
        ], day: Self.dayPath(for: Date().addingTimeInterval(-2 * 86_400)))
        #expect(result?.state == .running)
    }

    @Test("an open turn reads as running")
    func running() throws {
        let result = try actor(after: [
            Self.meta(),
            Self.event("task_started", ["turn_id": "019f54bd", "started_at": 1_783_833_129]),
            Self.event("user_message", ["message": "帮我看看无人机方向\n"]),
        ])
        #expect(result?.state == .running)
        #expect(result?.title == "帮我看看无人机方向")
        #expect(result?.source == "codex")
        #expect(result?.thread == Self.uuid)
        #expect(result?.id == "codex:\(Self.uuid)")
    }

    @Test("task_complete reads as review")
    func review() throws {
        let result = try actor(after: [
            Self.event("task_started", ["turn_id": "019f54bd"]),
            Self.event("task_complete", ["turn_id": "019f54bd", "last_agent_message": nil]),
        ])
        #expect(result?.state == .review)
    }

    @Test("an approval request reads as waiting")
    func waiting() throws {
        let result = try actor(after: [
            Self.event("task_started"),
            Self.event("exec_approval_request", ["command": "rm -rf build"]),
        ])
        #expect(result?.state == .waiting)
        #expect(result?.detail == "等待批准：rm -rf build")
    }

    @Test("reasoning and patch events stay running with a readable detail")
    func activityDetails() throws {
        let reasoning = try actor(after: [Self.event("agent_reasoning")])
        #expect(reasoning?.detail == "正在思考")
        let patch = try actor(after: [Self.event("patch_apply_begin")])
        #expect(patch?.detail == "正在修改文件")
    }

    @Test("an error event reads as failed")
    func failed() throws {
        let result = try actor(after: [Self.event("stream_error", ["error": "usage limit reached"])])
        #expect(result?.state == .failed)
        #expect(result?.detail == "usage limit reached")
    }

    @Test("an aborted turn leaves no actor")
    func abort() throws {
        let result = try actor(after: [
            Self.event("task_started"),
            Self.event("turn_aborted", ["reason": "user cancelled"]),
        ])
        #expect(result == nil)
    }

    @Test("token_count noise does not extend an actor's life")
    func noiseDoesNotRefresh() throws {
        let result = try actor(after: [
            Self.event("task_complete"),
            Self.event("token_count", ["total_tokens": 42_000]),
        ], shift: -200)
        #expect(result == nil)
    }

    @Test("a finished turn is still shown inside its ttl")
    func reviewInsideTTL() throws {
        let result = try actor(after: [Self.event("task_complete")], shift: -10)
        #expect(result?.state == .review)
    }

    @Test("a rollout that stopped being written is not resurrected")
    func historicRollout() throws {
        // The real July rollout on this machine: a complete turn, long expired.
        let result = try actor(after: [
            Self.meta(),
            Self.event("task_started"),
            Self.event("user_message", ["message": "继续\n"]),
            Self.event("task_complete"),
        ], shift: -3_600)
        #expect(result == nil)
    }

    @Test("the thread title comes from session_index.jsonl")
    func indexedTitle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-codex-\(UUID().uuidString)", isDirectory: true)
        let directory = try writeRollout([
            Self.meta(),
            Self.event("task_started"),
            Self.event("user_message", ["message": "原始提问"]),
        ], root: root)
        let index = #"{"id":"\#(Self.uuid)","thread_name":"无人机应用方向","updated_at":"2026-07-12T05:12:39.174357Z"}"#
        try (index + "\n").write(
            to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        #expect(CodexAdapter(codexRoot: directory).poll(now: Date()).first?.title == "无人机应用方向")
    }

    @Test("a missing sessions root is not an error")
    func missingRoot() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-codex-absent-\(UUID().uuidString)")
        #expect(CodexAdapter(codexRoot: absent).poll(now: Date()).isEmpty)
    }

    @Test("the session id is the uuid tail, not the start timestamp")
    func sessionIDParsing() {
        let url = URL(fileURLWithPath: "/x/rollout-2026-07-12T13-11-17-\(Self.uuid).jsonl")
        #expect(CodexAdapter.sessionID(from: url) == Self.uuid)
        #expect(CodexAdapter.sessionID(
            from: URL(fileURLWithPath: "/x/rollout-anonymous-thread.jsonl")) == "anonymous-thread")
    }

    @Test("records are read without depending on fractional seconds")
    func timestampParsing() {
        #expect(CodexRecord.dateParser.date(from: "2026-07-12T05:12:09.011Z") != nil)
        #expect(CodexRecord.fallbackDateParser.date(from: "2026-07-12T05:12:09Z") != nil)
    }
}
