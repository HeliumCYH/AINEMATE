import Foundation

/// Spots the moment a session stops working, from nothing but the snapshots the
/// pet already refreshes every second.
///
/// The rule is "was busy last tick, finished this tick". A session that is
/// already in `review` when the pet first sees it is not announced: the pet was
/// not there when it started, so calling it a fresh completion would claim news
/// it never witnessed (every launch would pop "完成" for old threads).
public struct CompletionWatch: Sendable {
    private var states: [String: PetState] = [:]

    public init() {}

    public mutating func observe(_ actors: [Actor]) -> [Actor] {
        let finished = actors.filter { $0.state == .review && Self.wasBusy(states[$0.id]) }
        states.removeAll(keepingCapacity: true)
        for actor in actors { states[actor.id] = actor.state }
        return finished
    }

    /// A session that asked a question and then ended its turn also completed;
    /// only the states with a spinner or a question under them count as busy.
    private static func wasBusy(_ state: PetState?) -> Bool {
        state == .running || state == .waiting
    }
}

/// What the pill above the pet says. A second session finishing inside the same
/// window adds to the count instead of restarting at one, and the window moves
/// to the latest finish, so the user reads the newest result.
public struct CompletionNotice: Equatable, Sendable {
    public let count: Int
    /// Product names (`Qoder`, `OpenCode`), deduplicated.
    public let agents: [String]
    public let until: Date

    public init(count: Int, agents: [String], until: Date) {
        self.count = count
        self.agents = agents
        self.until = until
    }

    public static func starting(
        finished: [Actor], now: Date, duration: TimeInterval,
        extending previous: CompletionNotice?
    ) -> CompletionNotice {
        let continuing = previous.flatMap { $0.isActive(at: now) ? $0 : nil }
        var agents = Set(continuing?.agents ?? [])
        agents.formUnion(finished.map(\.agentName))
        return CompletionNotice(
            count: (continuing?.count ?? 0) + finished.count,
            agents: agents.sorted(),
            until: now.addingTimeInterval(duration))
    }

    public var title: String { "完成 \(count) 项" }

    /// One product is named; a mixed window would need a sentence, and the count
    /// already carries the fact, so it falls back to the session number.
    public var agentLabel: String? {
        switch agents.count {
        case 0: return nil
        case 1: return agents[0]
        default: return "\(agents.count) 个会话"
        }
    }

    public func isActive(at now: Date) -> Bool { now < until }
}
