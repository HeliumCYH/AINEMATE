import Foundation

/// The card's session list: a session keeps the slot it started in, so a state
/// change never shuffles the rows under the pointer, and a finished session
/// floats to the top because it is the one asking for attention.
///
/// Selecting a session is not part of the order — the bubble moves to the row,
/// the row stays where it is. Sessions without a start stamp join at the end in
/// the order they were first seen; the list is bounded so a pet left running for
/// days does not grow a leak.
public struct SessionRoster: Sendable {
    private var order: [String] = []
    private var starts: [String: Date] = [:]
    private let capacity = 64

    public init() {}

    public mutating func arrange(_ actors: [Actor]) -> [Actor] {
        for actor in actors where !order.contains(actor.id) {
            insert(actor)
        }
        trim(live: Set(actors.map(\.id)))

        let slot = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return actors.sorted {
            let lhsFinished = $0.state == .review
            let rhsFinished = $1.state == .review
            if lhsFinished != rhsFinished { return lhsFinished }
            let lhsSlot = slot[$0.id] ?? Int.max
            let rhsSlot = slot[$1.id] ?? Int.max
            if lhsSlot != rhsSlot { return lhsSlot < rhsSlot }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// A session with a start stamp slots in where it started — which is what
    /// keeps the order right when the pet is relaunched mid-session.
    private mutating func insert(_ actor: Actor) {
        guard let start = actor.startedAt else {
            order.append(actor.id)
            return
        }
        starts[actor.id] = start
        var index = 0
        for (offset, id) in order.enumerated() {
            if let other = starts[id], other <= start { index = offset + 1 }
        }
        order.insert(actor.id, at: index)
    }

    /// Drops the oldest sessions that are gone from the snapshot; a session that
    /// comes back while its slot is still held keeps it.
    private mutating func trim(live: Set<String>) {
        var excess = order.count - capacity
        guard excess > 0 else { return }
        order.removeAll { id in
            guard excess > 0, !live.contains(id) else { return false }
            starts[id] = nil
            excess -= 1
            return true
        }
    }
}
