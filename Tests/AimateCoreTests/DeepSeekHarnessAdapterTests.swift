import Foundation
import Testing

@testable import AimateCore

/// Drives the Harness adapter with the store layout observed on this machine:
/// `~/.dsh/sessions/<cwd-slug>/<uuid>/session.v3.jsonl.zstd` as the liveness
/// anchor and `~/.dsh/storages/session_projcache/sessions/<uuid>.json` as the
/// state snapshot, whose row names and null shapes are copied from the real files.
struct DeepSeekHarnessAdapterTests {
    private static let uuid = "99f1befa-9694-49a0-a838-6d83b8ab4480"
    private static let slug = "--Users-me-Documents-Agentero--"

    /// Builds a projection body from row values, filling the rest the way an
    /// untouched session does.
    private static func projection(
        cwd: String? = "/Users/me/Documents/Agentero",
        rows: [String: Any]
    ) -> [String: Any] {
        var identity: [String: Any] = ["formatVersion": 3, "createdAt": 1_792_115_688_653]
        if let cwd { identity["cwd"] = cwd }
        var allRows: [String: Any] = [
            "title": ["ver": 1, "seq": 2, "val": NSNull()],
            "goal": ["ver": 6, "seq": 2, "val": [
                "current": NSNull(), "seenGoalIds": [Any](), "failure": NSNull(),
            ]],
            "plan": ["ver": 3, "seq": 2, "val": [
                "active": false, "wanted": NSNull(), "running": NSNull(),
            ]],
            "turnBoundary": ["ver": 2, "seq": 2, "val": [
                "openTurnStartSeq": NSNull(), "lastStepStartSeq": NSNull(), "lastTurn": 0,
            ]],
            "todos": ["ver": 2, "seq": 2, "val": NSNull()],
            "permissions": ["ver": 2, "seq": 2, "val": [
                "preset": "workspace-write", "sandbox": "workspace-write", "approval": "ask",
            ]],
        ]
        for (name, value) in rows { allRows[name] = ["ver": 1, "seq": 3, "val": value] }
        return ["version": 7, "record": ["identity": identity, "rows": allRows]]
    }

    private func store(
        _ rows: [String: Any],
        cwd: String? = "/Users/me/Documents/Agentero",
        logAge: TimeInterval = 0,
        writeLog: Bool = true
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-dsh-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let session = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(Self.slug, isDirectory: true)
            .appendingPathComponent(Self.uuid, isDirectory: true)
        let cache = root
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)

        let json = String(
            data: try JSONSerialization.data(withJSONObject: Self.projection(cwd: cwd, rows: rows)),
            encoding: .utf8)!
        try json.write(to: cache.appendingPathComponent(Self.uuid + ".json"),
                       atomically: true, encoding: .utf8)

        guard writeLog else { return root }
        let log = session.appendingPathComponent(DeepSeekHarnessAdapter.sessionLogName)
        try Data([0x28, 0xB5, 0x2F, 0xFD]).write(to: log)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: logAge)],
                             ofItemAtPath: log.path)
        return root
    }

    private func actor(after rows: [String: Any], logAge: TimeInterval = 0,
                       writeLog: Bool = true) throws -> Actor? {
        let root = try store(rows, logAge: logAge, writeLog: writeLog)
        return DeepSeekHarnessAdapter(root: root).poll(now: Date()).first
    }

    /// Writes the plugin's claim heartbeat the way `forwarder.js` does: second
    /// precision, one file per host pid, named after that pid.
    private func claim(
        in directory: URL, pid: Int32 = getpid(), sessions: [String],
        age: TimeInterval = 0
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -age))
        let body = ["pid": Int(pid), "at": at, "sessions": sessions] as [String: Any]
        let url = directory.appendingPathComponent("dsh-plugin-\(pid).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                             ofItemAtPath: url.path)
        return url
    }

    /// One session whose projection says it is mid-turn, plus whatever claims
    /// the caller planted beside it.
    private func polled(claimedSessions: [String]?, claimAge: TimeInterval = 0,
                        claimPid: Int32 = getpid()) throws -> [Actor] {
        let root = try store(["turnBoundary": ["openTurnStartSeq": 4, "lastTurn": 1]])
        let claims = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-dsh-claims-\(UUID().uuidString)", isDirectory: true)
        if let claimedSessions {
            _ = try claim(in: claims, pid: claimPid, sessions: claimedSessions, age: claimAge)
        }
        return DeepSeekHarnessAdapter(root: root, claimDirectory: claims)
            .poll(now: Date())
    }

    @Test("a fresh claim hands the session to the plugin")
    func claimed() throws {
        #expect(try polled(claimedSessions: [Self.uuid]).isEmpty)
    }

    @Test("a claim for another session leaves this one to the disk view")
    func claimElsewhere() throws {
        #expect(try polled(claimedSessions: ["6a0f0000-0000-0000-0000-000000000000"]).count == 1)
    }

    @Test("a stale claim lets the disk view resume")
    func staleClaim() throws {
        // Crashed or unloaded plugin: the heartbeat stops and nothing renews it.
        #expect(try polled(claimedSessions: [Self.uuid], claimAge: 60).count == 1)
    }

    @Test("a claim from a dead host is ignored")
    func deadClaim() throws {
        // A heartbeat outlives its process by up to the grace window; the pid is
        // what closes that gap.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        #expect(try polled(claimedSessions: [Self.uuid],
                           claimPid: ended.processIdentifier).count == 1)
    }

    @Test("no claim directory is not an error")
    func noClaims() throws {
        #expect(try polled(claimedSessions: nil).count == 1)
    }

    @Test("an unparseable heartbeat is ignored")
    func badClaim() throws {
        let root = try store(["turnBoundary": ["openTurnStartSeq": 4, "lastTurn": 1]])
        let claims = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-dsh-claims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: claims, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: claims.appendingPathComponent("dsh-plugin-9.json"))
        #expect(DeepSeekHarnessAdapter(root: root, claimDirectory: claims)
            .poll(now: Date()).count == 1)
    }

    @Test("an open turn boundary reads as running")
    func running() throws {
        let result = try actor(after: [
            "turnBoundary": ["openTurnStartSeq": 14, "lastStepStartSeq": 18, "lastTurn": 2],
        ])
        #expect(result?.state == .running)
        #expect(result?.source == "dsh")
        #expect(result?.thread == Self.uuid)
    }

    @Test("a closed turn with history reads as review")
    func review() throws {
        let result = try actor(after: ["turnBoundary": ["openTurnStartSeq": NSNull(), "lastTurn": 3]])
        #expect(result?.state == .review)
        #expect(result?.detail == "本轮结束，等你确认")
    }

    @Test("an untouched session yields no actor")
    func untouched() throws {
        #expect(try actor(after: [:]) == nil)
    }

    @Test("a goal failure reads as failed")
    func failed() throws {
        let result = try actor(after: [
            "goal": ["current": NSNull(), "seenGoalIds": [Any](),
                     "failure": ["message": "usage limit reached"]],
            "turnBoundary": ["openTurnStartSeq": 4, "lastTurn": 1],
        ])
        #expect(result?.state == .failed)
        #expect(result?.detail == "usage limit reached")
    }

    @Test("an active plan step is named in the detail")
    func planStep() throws {
        let result = try actor(after: [
            "plan": ["active": true, "wanted": "跑通渲染", "running": "接线播放器"],
            "turnBoundary": ["openTurnStartSeq": 7, "lastTurn": 1],
        ])
        #expect(result?.state == .running)
        #expect(result?.detail == "计划进行中：接线播放器")
    }

    @Test("todo rows are counted")
    func todos() throws {
        let result = try actor(after: [
            "todos": [
                ["content": "骨架", "status": "completed"],
                ["content": "播放器", "status": "in_progress"],
                ["content": "卡片", "status": "pending"],
            ],
            "turnBoundary": ["openTurnStartSeq": 3, "lastTurn": 0],
        ])
        #expect(result?.detail == "任务 1/3 项完成")
    }

    @Test("the runtime title wins over the working directory")
    func title() throws {
        let fromRows = try actor(after: ["title": "检查REA工具可用性",
                                         "turnBoundary": ["openTurnStartSeq": 9, "lastTurn": 0]])
        #expect(fromRows?.title == "检查REA工具可用性")
        let fromCwd = try actor(after: ["turnBoundary": ["openTurnStartSeq": 9, "lastTurn": 0]])
        #expect(fromCwd?.title == "DeepSeek · Agentero")
    }

    @Test("an approval policy alone is not reported as waiting")
    func noInventedWaiting() throws {
        // `permissions.approval == "ask"` is a policy, not an outstanding prompt;
        // claiming waiting from it would wake the pet for every session.
        let result = try actor(after: ["turnBoundary": ["openTurnStartSeq": 2, "lastTurn": 0]])
        #expect(result?.state == .running)
    }

    @Test("a session whose log stopped growing is dropped")
    func staleLog() throws {
        #expect(try actor(after: ["turnBoundary": ["openTurnStartSeq": 4, "lastTurn": 1]],
                          logAge: -3_600) == nil)
    }

    @Test("a projection without a session log is not discovered")
    func missingLog() throws {
        #expect(try actor(after: ["turnBoundary": ["openTurnStartSeq": 4, "lastTurn": 1]],
                          writeLog: false) == nil)
    }

    @Test("a missing store root is not an error")
    func missingRoot() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimate-dsh-absent-\(UUID().uuidString)")
        #expect(DeepSeekHarnessAdapter(root: absent).poll(now: Date()).isEmpty)
    }

    @Test("a projection written for a different row shape still decodes")
    func unknownRowShape() throws {
        // Older runtimes put a plain string where newer ones nest an object.
        let result = try actor(after: [
            "goal": ["current": "整理逆向报告", "failure": "sandbox denied"],
            "turnBoundary": ["openTurnStartSeq": NSNull(), "lastTurn": 5],
        ])
        #expect(result?.state == .failed)
        #expect(result?.title == "整理逆向报告")
    }
}
