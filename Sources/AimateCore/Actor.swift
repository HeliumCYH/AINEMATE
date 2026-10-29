import Foundation

/// One unit of agent activity the pet can render. Push-based senders write these
/// directly; pull-based adapters synthesise them from whatever the agent leaves
/// on disk.
public struct Actor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: String
    public var state: PetState
    /// Card headline — usually the user prompt or task name.
    public var title: String
    /// Secondary line: current tool, approval question, or error summary.
    public var detail: String?
    /// Session/thread identifier, used for grouping and click-through.
    public var thread: String?
    /// Button labels for a card that needs an answer, e.g. `["允许", "拒绝"]`.
    /// The pet only draws them; the sender decides what to do with the reply.
    public var options: [String]?
    /// Seconds after which this actor is stale. A sender that forgets to clear
    /// itself therefore falls back to idle instead of sticking at "running".
    public var ttl: TimeInterval
    public var updatedAt: Date
    /// When the session started, as opposed to when it last moved. Only the
    /// card's row order reads it, so a sender that does not know can leave it nil.
    public var startedAt: Date?
    public var pid: Int?

    public init(
        id: String,
        source: String,
        state: PetState,
        title: String,
        detail: String? = nil,
        thread: String? = nil,
        options: [String]? = nil,
        ttl: TimeInterval = 45,
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        pid: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.title = title
        self.detail = detail
        self.thread = thread
        self.options = options
        self.ttl = ttl
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.pid = pid
    }

    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > ttl
    }

    /// Filenames must stay unique across sources while remaining human-debuggable.
    public var fileName: String { Self.fileName(for: id) }

    public static func fileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(safe) + ".json"
    }

    /// The card-facing agent name. `source` is a namespace used for filenames and
    /// pruning, so `dsh` has to read back as the product a human would name.
    public var agentName: String { Self.agentName(for: source) }

    public static func agentName(for source: String) -> String {
        switch source {
        case "qoder": return "Qoder"
        case "codex": return "Codex"
        case "dsh": return "DeepSeek Harness"
        case "opencode": return "OpenCode"
        default: return source.prefix(1).uppercased() + source.dropFirst()
        }
    }
}

/// One agent per badge colour, keyed to the product's own brand. The names record
/// where each hue came from: `amber`, `indigo` and `azure` are sampled or published
/// brand colours, `ink` is OpenCode's literal monochrome palette, and `slate` is the
/// fallback for sources this build knows nothing about.
public extension Actor {
    enum AgentTint: String, CaseIterable {
        case amber, indigo, azure, ink, slate
    }

    static func agentTint(for source: String) -> AgentTint {
        switch source {
        case "qoder": return .amber
        case "codex": return .indigo
        case "dsh": return .azure
        case "opencode": return .ink
        default: return .slate
        }
    }
}

/// The answer a human clicked. Written by the pet, read by whoever asked —
/// a hook blocking on `pet-cli reply` is the intended consumer.
public struct ActorReply: Codable, Equatable, Sendable {
    public let actorId: String
    public let option: String
    public let at: Date

    public init(actorId: String, option: String, at: Date = Date()) {
        self.actorId = actorId
        self.option = option
        self.at = at
    }
}

public struct ActorSnapshot: Equatable, Sendable {
    public let actors: [Actor]
    public let dominant: Actor?

    public static let empty = ActorSnapshot(actors: [])

    /// Highest-priority live actor; ties broken by recency so a finished
    /// "review" does not hide a newer "waiting".
    public init(actors live: [Actor]) {
        let sorted = live.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.updatedAt > $1.updatedAt
        }
        self.actors = sorted
        self.dominant = sorted.first
    }
}
