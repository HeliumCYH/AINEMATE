import Foundation
import Testing

@testable import AimateCore

private func payload(_ fields: [String: Any]) -> [String: Any] {
    var base: [String: Any] = [
        "hook_event_name": "PermissionRequest",
        "session_id": "3f1a9c22-77bd-4c11-9a0e-0d2b1c4e5f60",
        "cwd": "/Users/dev/REA_project/AINEMATE",
        "permission_mode": "default",
    ]
    for (key, value) in fields { base[key] = value }
    return base
}

@Suite("qoder permission hook")
struct PermissionHookTests {
    @Test("the argument is the headline, the tool is the footnote")
    func bashAsk() {
        let ask = QoderPermissionHook.ask(for: payload([
            "tool_name": "Bash",
            "tool_input": ["command": "git push origin main"],
        ]))
        #expect(ask?.title == "git push origin main")
        #expect(ask?.detail == "Bash · AINEMATE")
        #expect(ask?.actorID.hasPrefix("ask:qoder:3f1a9c22:") == true)
    }

    @Test("an id has to survive between two separate processes")
    func stableIDs() {
        let input: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]
        let first = QoderPermissionHook.ask(for: payload(input))
        let second = QoderPermissionHook.ask(for: payload(input))
        #expect(first?.actorID == second?.actorID)
        // Same tool, different argument: a distinct question, not the same answer.
        #expect(QoderPermissionHook.ask(
            for: payload(["tool_name": "Bash", "tool_input": ["command": "ls"]]))?
            .actorID != first?.actorID)
    }

    @Test("the card gets one line, however the tool wrote it")
    func collapsed() {
        let ask = QoderPermissionHook.ask(for: payload([
            "tool_name": "Write",
            "tool_input": ["file_path": "/tmp/a.sql"],
        ]))
        #expect(ask?.title == "/tmp/a.sql")
        #expect(ask?.detail == "Write · AINEMATE")

        let multiline = QoderPermissionHook.ask(for: payload([
            "tool_name": "Bash",
            "tool_input": ["command": "make\n  clean\n"],
        ]))
        #expect(multiline?.title == "make clean")

        let long = QoderPermissionHook.ask(for: payload([
            "tool_name": "Bash",
            "tool_input": ["command": String(repeating: "x", count: 200)],
        ]))
        #expect(long?.title.count == 73)
        #expect(long?.title.hasSuffix("…") == true)
    }

    @Test("anything that is not an ask decides nothing")
    func refusesToGuess() {
        #expect(QoderPermissionHook.ask(for: payload([
            "hook_event_name": "PreToolUse", "tool_name": "Bash"])) == nil)
        #expect(QoderPermissionHook.ask(for: payload(["tool_name": ""])) == nil)
        #expect(QoderPermissionHook.ask(for: payload([:])) == nil)
        // A tool we cannot summarise still asks, just with the name as headline.
        #expect(QoderPermissionHook.ask(for: payload(["tool_name": "mcp__x__y"]))?
            .title == "mcp__x__y 请求批准")
    }

    @Test("only a known button yields a verdict")
    func decisions() {
        let allow = verdict(QoderPermissionHook.decision(forOption: QoderPermissionHook.allowOption))
        let deny = verdict(QoderPermissionHook.decision(forOption: QoderPermissionHook.denyOption))
        #expect(allow?["behavior"] as? String == "allow")
        #expect(deny?["behavior"] as? String == "deny")
        #expect(deny?["message"] != nil)
        // An unrecognised label must never turn into a grant.
        #expect(QoderPermissionHook.decision(forOption: "全部允许") == nil)
    }

    @Test("the verdict sits where the runtime looks for it")
    func envelope() throws {
        let raw = try #require(QoderPermissionHook.decision(forOption: QoderPermissionHook.allowOption))
        let root = try #require(json(raw))
        let hook = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(hook["hookEventName"] as? String == "PermissionRequest")
        #expect((hook["decision"] as? [String: Any])?["behavior"] as? String == "allow")
    }
}

private func json(_ data: Data?) -> [String: Any]? {
    data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
}

/// Unwrap the hook envelope down to the `decision` object the runtime reads.
private func verdict(_ data: Data?) -> [String: Any]? {
    guard let root = json(data),
          let hook = root["hookSpecificOutput"] as? [String: Any] else { return nil }
    return hook["decision"] as? [String: Any]
}
