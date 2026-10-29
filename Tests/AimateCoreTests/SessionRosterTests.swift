import Foundation
import Testing
@testable import AimateCore

struct SessionRosterTests {
    private func actor(_ id: String, _ state: PetState, at: Date = Date(),
                       started: Date? = nil) -> Actor {
        Actor(id: id, source: "qoder", state: state, title: id,
              updatedAt: at, startedAt: started)
    }

    private func ids(_ actors: [Actor]) -> [String] { actors.map(\.id) }

    @Test func keepsFirstSeenOrder() {
        var roster = SessionRoster()
        let first = roster.arrange([
            actor("a", .running, at: Date(timeIntervalSince1970: 100)),
            actor("b", .running, at: Date(timeIntervalSince1970: 200)),
        ])
        #expect(ids(first) == ["a", "b"])

        // A state change and a fresher timestamp must not reorder the rows.
        let second = roster.arrange([
            actor("b", .running, at: Date(timeIntervalSince1970: 400)),
            actor("a", .running, at: Date(timeIntervalSince1970: 300)),
        ])
        #expect(ids(second) == ["a", "b"])
    }

    @Test func newSessionAppends() {
        var roster = SessionRoster()
        _ = roster.arrange([actor("a", .running), actor("b", .running)])
        let rows = roster.arrange([
            actor("c", .running), actor("a", .running), actor("b", .running),
        ])
        #expect(ids(rows) == ["a", "b", "c"])
    }

    @Test func finishedFloatsToTop() {
        var roster = SessionRoster()
        _ = roster.arrange([actor("a", .running), actor("b", .running)])
        let rows = roster.arrange([
            actor("a", .running), actor("b", .review),
        ])
        #expect(ids(rows) == ["b", "a"])
    }

    @Test func finishedKeepsStartOrder() {
        var roster = SessionRoster()
        _ = roster.arrange([
            actor("a", .running), actor("b", .running), actor("c", .running),
        ])
        let rows = roster.arrange([
            actor("c", .review), actor("a", .running), actor("b", .review),
        ])
        #expect(ids(rows) == ["b", "c", "a"])
    }

    @Test func failedKeepsItsSlot() {
        var roster = SessionRoster()
        _ = roster.arrange([actor("a", .running), actor("b", .running)])
        let rows = roster.arrange([
            actor("a", .failed), actor("b", .running),
        ])
        #expect(ids(rows) == ["a", "b"])
    }

    @Test func returningSessionKeepsItsSlot() {
        var roster = SessionRoster()
        _ = roster.arrange([actor("a", .running), actor("b", .running)])
        _ = roster.arrange([actor("b", .running)])
        let rows = roster.arrange([actor("a", .running), actor("b", .running)])
        #expect(ids(rows) == ["a", "b"])
    }

    @Test func arrangingIsIdempotent() {
        var roster = SessionRoster()
        let once = roster.arrange([
            actor("a", .review), actor("b", .running), actor("c", .running),
        ])
        let twice = roster.arrange(once)
        #expect(ids(once) == ids(twice))
    }

    @Test func startStampBeatsArrivalOrder() {
        var roster = SessionRoster()
        let t = Date(timeIntervalSince1970: 1000)
        let rows = roster.arrange([
            actor("b", .running, at: t, started: t.addingTimeInterval(200)),
            actor("a", .running, at: t, started: t.addingTimeInterval(100)),
        ])
        #expect(ids(rows) == ["a", "b"])
    }

    @Test func lateArrivalSlotsInAtItsStart() {
        var roster = SessionRoster()
        let t = Date(timeIntervalSince1970: 1000)
        _ = roster.arrange([actor("a", .running, at: t, started: t)])
        _ = roster.arrange([
            actor("a", .running, at: t, started: t),
            actor("c", .running, at: t, started: t.addingTimeInterval(20)),
        ])
        let rows = roster.arrange([
            actor("a", .running, at: t, started: t),
            actor("b", .running, at: t, started: t.addingTimeInterval(10)),
            actor("c", .running, at: t, started: t.addingTimeInterval(20)),
        ])
        #expect(ids(rows) == ["a", "b", "c"])
    }

    @Test func finishedLeadsEvenWithStartStamps() {
        var roster = SessionRoster()
        let t = Date(timeIntervalSince1970: 1000)
        let rows = roster.arrange([
            actor("a", .running, at: t, started: t),
            actor("b", .review, at: t, started: t.addingTimeInterval(60)),
        ])
        #expect(ids(rows) == ["b", "a"])
    }
}
