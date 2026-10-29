import Foundation

/// One record from `~/.qoder-cn/logs/sessions/<project>/<session>/segments/*.jsonl`.
/// Only the fields that carry pet meaning are decoded; `data` is heterogeneous
/// across event types so every member is optional.
struct QoderEvent: Decodable {
    let ts: String
    let level: String
    let type: String
    let turnId: String?
    let toolCallId: String?
    let data: Payload?

    enum CodingKeys: String, CodingKey {
        case ts, level, type, data
        case turnId = "turn_id"
        case toolCallId = "tool_call_id"
    }

    struct Payload: Decodable {
        let reason: String?
        let error: String?
        let textPreview: String?
        let isMeta: Bool?
        let isSubagent: Bool?
        let toolName: String?
        let askMessage: String?
        let status: String?
        let allowed: Bool?
        let source: String?
        let durationMs: Int?
        let forkLabel: String?

        init(
            reason: String? = nil, error: String? = nil, textPreview: String? = nil,
            isMeta: Bool? = nil, isSubagent: Bool? = nil, toolName: String? = nil,
            askMessage: String? = nil, status: String? = nil, allowed: Bool? = nil,
            source: String? = nil, durationMs: Int? = nil, forkLabel: String? = nil
        ) {
            self.reason = reason
            self.error = error
            self.textPreview = textPreview
            self.isMeta = isMeta
            self.isSubagent = isSubagent
            self.toolName = toolName
            self.askMessage = askMessage
            self.status = status
            self.allowed = allowed
            self.source = source
            self.durationMs = durationMs
            self.forkLabel = forkLabel
        }

        enum CodingKeys: String, CodingKey {
            case reason, error, status, allowed, source
            case textPreview = "text_preview"
            case isMeta = "is_meta"
            case isSubagent = "is_subagent"
            case toolName = "tool_name"
            case askMessage = "ask_message"
            case durationMs = "duration_ms"
            case forkLabel = "fork_label"
        }
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// Event clocks are the sender's, and the pet must age an actor from the
    /// moment the agent actually spoke — not from the moment we noticed.
    var date: Date? {
        Self.fractional.date(from: ts) ?? Self.plain.date(from: ts)
    }
}
