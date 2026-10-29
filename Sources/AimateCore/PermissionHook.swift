import Foundation

/// Bridges a Qoder `PermissionRequest` hook to the pet's ask channel, and the
/// button the human clicked back to the decision JSON the runtime reads on
/// stdout.
///
/// The fail-safe is the whole point of keeping this pure: anything it cannot
/// read or understand comes back as `nil`, and "say nothing" is what makes the
/// agent fall through to its own approval prompt. Verified against the SDK
/// worker runtime — a hook with no verdict never settles the permission race,
/// so the pet can only ever add an answer channel, never replace one.
public enum QoderPermissionHook {
    public static let allowOption = "允许一次"
    public static let denyOption = "拒绝"
    public static let options = [allowOption, denyOption]

    public struct Ask: Equatable {
        public let actorID: String
        public let title: String
        public let detail: String
    }

    /// nil unless this is a permission ask we can name.
    public static func ask(for payload: [String: Any]) -> Ask? {
        guard payload["hook_event_name"] as? String == "PermissionRequest",
              let toolName = payload["tool_name"] as? String,
              !toolName.isEmpty else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let session = payload["session_id"] as? String ?? "unknown"
        let subject = subjectLine(for: toolName, input: input)
        return Ask(
            // `ask:` is a namespace no adapter owns. The engine prunes every file
            // prefixed with an adapter's source, so an ask published as `qoder:…`
            // was deleted on the next tick and never reached the card.
            actorID: "ask:qoder:\(sessionID(session)):\(digest("\(toolName)\u{1}\(subject)"))",
            title: subject.isEmpty ? "\(toolName) 请求批准" : subject,
            detail: contextLine(for: toolName, payload: payload))
    }

    /// The tool's own words are the only thing worth reading on a 232pt card, so
    /// the headline is the argument; the tool name is demoted to the detail line.
    private static func subjectLine(for toolName: String, input: [String: Any]) -> String {
        let keys: [String]
        switch toolName {
        case "Bash": keys = ["command"]
        case "Read", "Write", "Edit", "NotebookEdit": keys = ["file_path", "notebook_path"]
        case "Grep", "Glob": keys = ["pattern"]
        case "WebFetch": keys = ["url"]
        case "WebSearch": keys = ["query"]
        case "Agent": keys = ["description", "prompt"]
        default: keys = []
        }
        for key in keys {
            guard let raw = input[key] as? String else { continue }
            let flat = splittingNewlines(raw).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !flat.isEmpty { return flat.count > 72 ? String(flat.prefix(72)) + "…" : flat }
        }
        return ""
    }

    private static func contextLine(for toolName: String, payload: [String: Any]) -> String {
        guard let cwd = payload["cwd"] as? String else { return toolName }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? toolName : "\(toolName) · \(name)"
    }

    private static func splittingNewlines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Only `allow` and `deny` are ever emitted: an unrecognised option must not
    /// silently become a grant.
    public static func decision(forOption option: String) -> Data? {
        let behavior: String
        var decision: [String: Any]
        switch option {
        case allowOption: behavior = "allow"; decision = [:]
        case denyOption: behavior = "deny"; decision = ["message": "已在桌宠上拒绝"]
        default: return nil
        }
        decision["behavior"] = behavior
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: output)
    }

    /// Swift's `hashValue` is seeded per process, so an id that has to survive
    /// between two different programs needs a fixed digest.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return hex.count >= 16 ? hex : String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Session ids are uuids; the card shows them nowhere, but keeping the head
    /// makes the actor file greppable against a transcript.
    private static func sessionID(_ raw: String) -> String {
        String(String(raw.prefix(8)).lowercased().map { $0.isHexDigit ? $0 : "-" })
    }
}
