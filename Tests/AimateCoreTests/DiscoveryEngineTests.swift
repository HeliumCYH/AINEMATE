import Foundation
import Testing

@testable import AimateCore

private final class FixedAdapter: AgentAdapter {
    let source: String
    var actors: [Actor]
    init(source: String, actors: [Actor] = []) {
        self.source = source
        self.actors = actors
    }

    func poll(now: Date) -> [Actor] { actors }
}

private func tempStore(_ label: String) -> (URL, ActorStore) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("aimate-engine-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, ActorStore(directory: dir))
}

private func exists(_ dir: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
}

@Suite("discovery engine")
struct DiscoveryEngineTests {
    @Test("an actor the engine published survives the prune")
    func publishedSurvivesPrune() {
        // The renderer drops actors whose sender pid is gone, but the file is the
        // contract: pruning by what the renderer happens to accept deletes actors
        // that are perfectly current, and the pet then shows nothing at all.
        let (dir, store) = tempStore("publish")
        let actor = Actor(
            id: "qoder:s1", source: "qoder", state: .running, title: "继续测试",
            ttl: 180, updatedAt: Date(), pid: Int(Int32.max))
        let engine = DiscoveryEngine(store: store, adapters: [FixedAdapter(source: "qoder", actors: [actor])])
        engine.tick()
        #expect(exists(dir, "qoder-s1.json"))
    }

    @Test("an orphan from a previous process is pruned, a push sender is not")
    func prunesOnlyItsOwnOrphans() {
        let (dir, store) = tempStore("orphan")
        let gone = Actor(
            id: "qoder:gone", source: "qoder", state: .running, title: "上一次进程留下的",
            ttl: 180, updatedAt: Date())
        let pushed = Actor(id: "cli:build", source: "cli", state: .waiting, title: "外部推送", ttl: 900)
        store.publish(gone)
        store.publish(pushed)

        DiscoveryEngine(store: store, adapters: [FixedAdapter(source: "qoder")]).tick()
        #expect(!exists(dir, "qoder-gone.json"))
        #expect(exists(dir, "cli-build.json"))
    }

    @Test("a permission ask survives the tick of the agent it belongs to")
    func askOutlivesItsSource() throws {
        // Source drives the badge, the id namespace drives ownership. An approval
        // asked by a Qoder hook is `source: qoder` but `ask:qoder:…`; if it shared
        // the adapter's prefix the engine deleted the question mid-flight and the
        // hook blocked on a card the user never saw.
        let (dir, store) = tempStore("ask")
        let ask = QoderPermissionHook.ask(for: [
            "hook_event_name": "PermissionRequest",
            "session_id": "3f1a9c22-77bd-4c11-9a0e-0d2b1c4e5f60",
            "tool_name": "Bash",
            "tool_input": ["command": "git push origin main"],
        ])
        let id = try #require(ask?.actorID)
        store.publish(Actor(id: id, source: "qoder", state: .waiting,
                            title: "git push origin main", ttl: 200))
        DiscoveryEngine(store: store, adapters: [FixedAdapter(source: "qoder")]).tick()
        #expect(exists(dir, Actor.fileName(for: id)))
    }

    @Test("an actor that stops being reported is cleared on the next tick")
    func clearsWhenItStops() {
        let (dir, store) = tempStore("clear")
        let adapter = FixedAdapter(source: "qoder", actors: [
            Actor(id: "qoder:s2", source: "qoder", state: .running, title: "在跑", ttl: 180),
        ])
        let engine = DiscoveryEngine(store: store, adapters: [adapter])
        engine.tick()
        #expect(exists(dir, "qoder-s2.json"))
        adapter.actors = []
        engine.tick()
        #expect(!exists(dir, "qoder-s2.json"))
    }
}
