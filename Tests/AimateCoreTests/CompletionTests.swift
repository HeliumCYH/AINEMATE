import Foundation
import Testing
@testable import AimateCore

struct CompletionWatchTests {
    private func actor(_ id: String, _ state: PetState, source: String = "qoder") -> Actor {
        Actor(id: id, source: source, state: state, title: id)
    }

    @Test("a session that was busy and now finished is announced once")
    func busyToReviewAnnounced() {
        var watch = CompletionWatch()
        #expect(watch.observe([actor("a", .running)]).isEmpty)
        #expect(watch.observe([actor("a", .review)]).map(\.id) == ["a"])
        // The review state stays for its ttl; it must not fire again every tick.
        #expect(watch.observe([actor("a", .review)]).isEmpty)
    }

    @Test("a session first seen in review is old news, not a completion")
    func firstSeenReviewSilent() {
        var watch = CompletionWatch()
        #expect(watch.observe([actor("old", .review)]).isEmpty)
        #expect(watch.observe([actor("old", .review)]).isEmpty)
    }

    @Test("an answered ask that ends its turn also completed")
    func waitingToReviewAnnounced() {
        var watch = CompletionWatch()
        _ = watch.observe([actor("ask", .waiting)])
        #expect(watch.observe([actor("ask", .review)]).map(\.id) == ["ask"])
    }

    @Test("a failure or a plain state change is not a completion")
    func nonCompletions() {
        var watch = CompletionWatch()
        _ = watch.observe([actor("a", .failed)])
        #expect(watch.observe([actor("a", .review)]).isEmpty)
        _ = watch.observe([actor("b", .running)])
        #expect(watch.observe([actor("b", .failed)]).isEmpty)
        #expect(watch.observe([actor("b", .running)]).isEmpty)
    }

    @Test("a session that expired and came back in review is not announced")
    func expiredThenReviewSilent() {
        var watch = CompletionWatch()
        _ = watch.observe([actor("a", .running)])
        #expect(watch.observe([]).isEmpty)
        #expect(watch.observe([actor("a", .review)]).isEmpty)
    }
}

struct CompletionNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func qoder(_ id: String = "s1") -> Actor {
        Actor(id: id, source: "qoder", state: .review, title: id)
    }

    @Test("the pill reads its count and the one product that finished")
    func singleProduct() {
        let notice = CompletionNotice.starting(
            finished: [qoder()], now: now, duration: 3, extending: nil)
        #expect(notice.title == "完成 1 项")
        #expect(notice.agentLabel == "Qoder")
        #expect(notice.until == now.addingTimeInterval(3))
    }

    @Test("a second finish inside the window adds to the count")
    func accumulates() {
        let first = CompletionNotice.starting(
            finished: [qoder()], now: now, duration: 3, extending: nil)
        let second = CompletionNotice.starting(
            finished: [qoder("s2")], now: now.addingTimeInterval(1.5),
            duration: 3, extending: first)
        #expect(second.count == 2)
        #expect(second.agents == ["Qoder"])
        #expect(second.title == "完成 2 项")
        #expect(second.until == now.addingTimeInterval(4.5))
    }

    @Test("a finish after the window starts the count over")
    func resetsAfterWindow() {
        let first = CompletionNotice.starting(
            finished: [qoder()], now: now, duration: 3, extending: nil)
        #expect(!first.isActive(at: now.addingTimeInterval(3)))
        let later = CompletionNotice.starting(
            finished: [qoder("s2")], now: now.addingTimeInterval(5),
            duration: 3, extending: first)
        #expect(later.count == 1)
        #expect(later.until == now.addingTimeInterval(8))
    }

    @Test("two products in one window are counted, not named")
    func mixedProducts() {
        let first = CompletionNotice.starting(
            finished: [qoder()], now: now, duration: 3, extending: nil)
        let second = CompletionNotice.starting(
            finished: [Actor(id: "oc", source: "opencode", state: .review, title: "oc")],
            now: now.addingTimeInterval(1), duration: 3, extending: first)
        #expect(second.agents == ["OpenCode", "Qoder"])
        #expect(second.agentLabel == "2 个会话")
    }
}
