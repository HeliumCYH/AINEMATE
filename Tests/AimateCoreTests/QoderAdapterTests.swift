import Foundation
import Testing

@testable import AimateCore

/// Drives the adapter with synthetic logs shaped like the real
/// `~/.qoder-cn/logs/sessions` stream, so state mapping is verified without
/// depending on a live Qoder process.
struct QoderAdapterTests {
    struct Event {
        let type: String
        let data: [String: Any]
        let toolCallId: String?
        init(_ type: String, _ data: [String: Any] = [:], toolCallId: String? = nil) {
            self.type = type
            self.data = data
            self.toolCallId = toolCallId
        }
    }

    private static let segmentName = "2026-10-28T10-00-00-000+08-00-abc123-p99999.jsonl"
    private static let projectPath = "-Users-me/proj-1/segments"

    /// Writes `<root>/<project>/<session>/segments/<run-id>-p<pid>.jsonl` with
    /// timestamps one second apart, the final one `shift` seconds before `now`.
    private func writeLog(_ events: [Event], shift: TimeInterval = 0) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-qoder-\(UUID().uuidString)", isDirectory: true)
        let segments = root.appendingPathComponent(Self.projectPath, isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let url = segments.appendingPathComponent(Self.segmentName)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date().addingTimeInterval(shift - Double(events.count))

        var lines: [String] = []
        for (index, event) in events.enumerated() {
            var record: [String: Any] = [
                "ts": formatter.string(from: base.addingTimeInterval(TimeInterval(index))),
                "seq": index,
                "level": "info",
                "type": event.type,
                "data": event.data,
            ]
            if let call = event.toolCallId { record["tool_call_id"] = call }
            lines.append(String(
                data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)!)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return root
    }

    private func actor(after events: [Event], shift: TimeInterval = 0) throws -> Actor? {
        QoderAdapter(sessionsRoot: try writeLog(events, shift: shift)).poll(now: Date()).first
    }

    /// Drops a second segment into an existing session, the way a restarted Qoder
    /// run does: new file name, new worker pid, same session id.
    private func writeRun(_ events: [Event], into root: URL, name: String) throws {
        let segments = root.appendingPathComponent(Self.projectPath, isDirectory: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date().addingTimeInterval(-Double(events.count))
        var lines: [String] = []
        for (index, event) in events.enumerated() {
            let record: [String: Any] = [
                "ts": formatter.string(from: base.addingTimeInterval(TimeInterval(index))),
                "seq": 100 + index,
                "level": "info",
                "type": event.type,
                "data": event.data,
            ]
            lines.append(String(
                data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)!)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: segments.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("a restarted run takes over the worker pid")
    func restartedRun() throws {
        let root = try writeLog([
            Event("turn.started"), Event("tool.requested", ["tool_name": "Read"]),
        ])
        let adapter = QoderAdapter(sessionsRoot: root)
        #expect(adapter.poll(now: Date()).first?.pid == 99999)

        try writeRun(
            [Event("tool.requested", ["tool_name": "Bash"])], into: root,
            name: "2026-10-29T11-31-47-665+08-00-rc71rr-p31385.jsonl")
        let result = adapter.poll(now: Date()).first
        #expect(result?.pid == 31385)
        #expect(result?.state == .running)
    }

    @Test("prompt plus tools reads as running")
    func running() throws {
        let state = try actor(after: [
            Event("input.prompt.submitted", ["text_preview": "复刻桌宠", "is_meta": false, "is_subagent": false]),
            Event("turn.started", ["model": "qfmodel"]),
            Event("tool.requested", ["tool_name": "Bash"]),
        ])?.state
        #expect(state == .running)
    }

    @Test("an unanswered approval reads as waiting")
    func waiting() throws {
        let result = try actor(after: [
            Event("turn.started"),
            Event("permission.requested", ["tool_name": "Bash", "ask_message": "Allow rm?"], toolCallId: "call-1"),
            Event("tool.requested", ["tool_name": "Read"]),
        ])
        #expect(result?.state == .waiting)
        #expect(result?.detail == "Allow rm?")
    }

    @Test("resolving the only approval returns to running")
    func resolved() throws {
        let state = try actor(after: [
            Event("permission.requested", ["tool_name": "Bash", "ask_message": "Allow?"], toolCallId: "call-1"),
            Event("permission.resolved", ["tool_name": "Bash", "allowed": true], toolCallId: "call-1"),
        ])?.state
        #expect(state == .running)
    }

    @Test("a second approval still outstanding keeps waiting")
    func secondApproval() throws {
        let state = try actor(after: [
            Event("permission.requested", ["tool_name": "Bash"], toolCallId: "call-1"),
            Event("permission.requested", ["tool_name": "Write"], toolCallId: "call-2"),
            Event("permission.resolved", ["tool_name": "Bash", "allowed": true], toolCallId: "call-1"),
        ])?.state
        #expect(state == .waiting)
    }

    @Test("end_turn reads as review")
    func review() throws {
        let result = try actor(after: [
            Event("tool.requested", ["tool_name": "Bash"]),
            Event("turn.finished", ["reason": "end_turn", "duration_ms": 65_000]),
        ])
        #expect(result?.state == .review)
        #expect(result?.detail == "用时 1 分 5 秒")
    }

    @Test("a new turn drops the previous turn's outcome line")
    func newTurnClearsOutcome() throws {
        let result = try actor(after: [
            Event("input.prompt.submitted", ["text_preview": "复刻桌宠", "is_meta": false, "is_subagent": false]),
            Event("tool.requested", ["tool_name": "Bash"]),
            Event("turn.finished", ["reason": "end_turn", "duration_ms": 32_000]),
            Event("input.prompt.submitted", ["text_preview": "接着做任务卡", "is_meta": false, "is_subagent": false]),
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == nil)
    }

    @Test("Qoder's own Recap conversation is never shown")
    func recapIsInternal() throws {
        // Observed on 2026-10-29: a hidden conversation per task, opened with this
        // exact preamble and carrying neither is_meta nor is_subagent.
        let result = try actor(after: [
            Event("input.prompt.submitted", [
                "text_preview": "你正在为 Qoder 任务监控编写简短的会话 Recap。\n只返回一个 JSON 对象：{\"recap\":\"...\"}",
                "is_meta": false, "is_subagent": false,
            ]),
            Event("turn.started"),
            Event("turn.finished", ["reason": "end_turn", "duration_ms": 3_997]),
        ])
        #expect(result == nil)
    }

    @Test("a prompt that merely mentions Recap is still a real session")
    func recapMentionIsNotInternal() throws {
        let result = try actor(after: [
            Event("input.prompt.submitted", [
                "text_preview": "为什么 Recap 会话会抢卡片？", "is_meta": false, "is_subagent": false,
            ]),
            Event("turn.started"),
        ])
        #expect(result?.state == .running)
    }

    @Test("error turn reads as failed and carries the message")
    func failed() throws {
        let result = try actor(after: [
            Event("turn.finished", ["reason": "error", "error": "daily usage limit"]),
        ])
        #expect(result?.state == .failed)
        #expect(result?.detail == "daily usage limit")
    }

    @Test("abort leaves no actor")
    func abort() throws {
        let state = try actor(after: [
            Event("turn.started"),
            Event("turn.finished", ["reason": "abort"]),
        ])?.state
        #expect(state == nil)
    }

    @Test("max_turns asks for help")
    func maxTurns() throws {
        let state = try actor(after: [Event("turn.finished", ["reason": "max_turns"])])?.state
        #expect(state == .waiting)
    }

    @Test("the user prompt becomes the title, but a subagent prompt does not")
    func title() throws {
        let result = try actor(after: [
            Event("input.prompt.submitted", ["text_preview": "帮我搭桌宠", "is_meta": false, "is_subagent": false]),
            Event("input.prompt.submitted", ["text_preview": "Review this conversation", "is_meta": false, "is_subagent": true]),
            Event("turn.started"),
        ])
        #expect(result?.title == "帮我搭桌宠")
        #expect(result?.source == "qoder")
        #expect(result?.pid == 99999)
    }

    @Test("noise records do not extend an actor's life")
    func noiseDoesNotRefresh() throws {
        // The review is the last state event; hook and phase noise after it must
        // not refresh the TTL, so 200s later the 20s review actor has lapsed.
        let result = try actor(after: [
            Event("turn.finished", ["reason": "end_turn"]),
            Event("hook.finished", ["phase": "x"]),
            Event("session.phase.started", ["phase": "mcp_context.refresh"]),
        ], shift: -200)
        #expect(result == nil)
    }

    @Test("a live review actor is reported while inside its ttl")
    func reviewInsideTTL() throws {
        let result = try actor(after: [
            Event("turn.finished", ["reason": "end_turn"]),
            Event("hook.finished", ["phase": "x"]),
        ], shift: -10)
        #expect(result?.state == .review)
    }

    @Test("a quiet running turn stays live while its worker process is")
    func quietRunningKeepsWorkerSignal() {
        // Observed in real Qoder logs: 16:36:56 tool.requested → 16:43:56
        // tool.execution.finished, seven minutes of nothing. The 180s ttl used
        // to blank the pet in the middle of that command.
        let now = Date()
        let worker = Int(getpid())
        func actor(quiet seconds: TimeInterval) -> Actor? {
            ActorRules.actor(
                source: "qoder", id: "s1", foldState: .running,
                foldUpdated: now.addingTimeInterval(-seconds), now: now,
                activityWindow: 900, title: "构建", detail: nil, pid: worker)
        }
        #expect(actor(quiet: 600)?.state == .running)
        #expect(actor(quiet: 600)?.ttl == 900)
        // The activity window still bounds a turn nobody ever closed.
        #expect(actor(quiet: 1000) == nil)
    }

    @Test("a finished turn keeps its short ttl even with a live worker")
    func reviewTTLDoesNotStretch() {
        let now = Date()
        let result = ActorRules.actor(
            source: "qoder", id: "s1", foldState: .review,
            foldUpdated: now.addingTimeInterval(-200), now: now,
            activityWindow: 900, title: "构建", detail: nil, pid: Int(getpid()))
        #expect(result == nil)
    }

    @Test("a stale segment file is not discovered")
    func staleFile() throws {
        let root = try writeLog([Event("turn.started")])
        let segment = root.appendingPathComponent(Self.projectPath)
            .appendingPathComponent(Self.segmentName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: segment.path)
        #expect(QoderAdapter(sessionsRoot: root).poll(now: Date()).isEmpty)
    }

    @Test("a missing log root is not an error")
    func missingRoot() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-absent-\(UUID().uuidString)")
        #expect(QoderAdapter(sessionsRoot: absent).poll(now: Date()).isEmpty)
    }

    @Test("the worker pid is taken from the run id")
    func pidParsing() {
        let url = URL(fileURLWithPath: "/tmp/2026-10-28T19-42-27-569+08-00-g4uyeh-p59656.jsonl")
        #expect(QoderAdapter.pid(from: url) == 59656)
    }

    @Test("the tailer resumes, and restarts after a truncate")
    func tailing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-tail-\(UUID().uuidString).jsonl")
        let tailer = JSONLTailer()
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(tailer.readLines(from: url) == ["a", "b"])
        #expect(tailer.readLines(from: url) == nil)

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("c\n".utf8))
        try handle.close()
        #expect(tailer.readLines(from: url) == ["c"])

        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(tailer.readLines(from: url) == ["x"])
    }

    @Test("a half-written record is re-read once completed, not lost")
    func partialLine() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-tail-\(UUID().uuidString).jsonl")
        let tailer = JSONLTailer()
        try "{\"type\":\"a\"}\n{\"type\":\"b\"".write(to: url, atomically: true, encoding: .utf8)
        #expect(tailer.readLines(from: url) == ["{\"type\":\"a\"}"])

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("}\n".utf8))
        try handle.close()
        #expect(tailer.readLines(from: url) == ["{\"type\":\"b\"}"])
    }
}
