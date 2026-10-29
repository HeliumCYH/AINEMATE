import Foundation
import Testing

@testable import AimateCore

private func makeTempDir(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("aimate-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("actor store")
struct ActorStoreTests {
    @Test("a pushed actor survives a fresh reader")
    func roundTrip() {
        let dir = makeTempDir("push")
        let actor = Actor(id: "cli:build", source: "cli", state: .running, title: "编译中")
        ActorStore(directory: dir).publish(actor)
        let reloaded = ActorStore(directory: dir).snapshot()
        #expect(reloaded.dominant?.title == "编译中")
        #expect(reloaded.dominant?.state == .running)
    }

    @Test("the card names the product, and every agent gets its own colour")
    func agentNames() {
        #expect(Actor(id: "dsh:x", source: "dsh", state: .running, title: "t").agentName
                == "DeepSeek Harness")
        #expect(Actor(id: "qoder:x", source: "qoder", state: .running, title: "t").agentName == "Qoder")
        // A pet-cli sender's own namespace still reads as a label, not "dsh".
        #expect(Actor(id: "mine:x", source: "mine", state: .running, title: "t").agentName == "Mine")
        let tints = ["qoder", "codex", "dsh", "opencode"].map { Actor.agentTint(for: $0) }
        #expect(Set(tints).count == 4)
    }

    @Test("a reply round-trips, and a fresh ask retires it")
    func replies() {
        let dir = makeTempDir("replies")
        let store = ActorStore(directory: dir,
                               repliesDirectory: dir.appendingPathComponent("replies", isDirectory: true))
        var actor = Actor(id: "cli:build", source: "cli", state: .waiting,
                          title: "要放行 rm 吗？", options: ["允许", "拒绝"])
        #expect(actor.options == ["允许", "拒绝"])
        #expect(store.reply(for: actor) == nil)
        store.record(ActorReply(actorId: actor.id, option: "允许",
                                at: actor.updatedAt.addingTimeInterval(1)))
        #expect(store.reply(for: actor)?.option == "允许")
        // The sender asking again is a new question, not one already answered.
        actor.updatedAt = actor.updatedAt.addingTimeInterval(10)
        #expect(store.reply(for: actor) == nil)
    }

    @Test("the heartbeat only counts while the pet is really ticking")
    func heartbeat() throws {
        let dir = makeTempDir("heartbeat")
        let stamp = dir.appendingPathComponent("live.stamp")
        let store = ActorStore(directory: dir,
                               repliesDirectory: dir.appendingPathComponent("replies", isDirectory: true),
                               heartbeatFile: stamp)
        // No pet has ever run here.
        #expect(!store.petIsAlive())
        store.markAlive()
        #expect(store.petIsAlive())
        // A pet that died leaves the stamp behind; age is what kills it.
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: stamp.path)
        #expect(!store.petIsAlive())
    }

    @Test("an expired actor is ignored, so a forgetful sender cannot stick the pet")
    func expiry() {
        let dir = makeTempDir("expiry")
        ActorStore(directory: dir).publish(Actor(
            id: "stale", source: "cli", state: .waiting, title: "gone",
            ttl: 30, updatedAt: Date(timeIntervalSinceNow: -120)))
        #expect(ActorStore(directory: dir).snapshot().actors.isEmpty)
    }

    @Test("a dead pid drops the actor even with a long ttl")
    func deadSender() {
        let dir = makeTempDir("dead")
        ActorStore(directory: dir).publish(Actor(
            id: "orphan", source: "cli", state: .running, title: "orphan",
            ttl: 3600, updatedAt: Date(), pid: Int(Int32.max)))
        #expect(ActorStore(directory: dir).snapshot().actors.isEmpty)
    }

    @Test("clear removes the file")
    func clear() {
        let dir = makeTempDir("clear")
        let store = ActorStore(directory: dir)
        store.publish(Actor(id: "qoder:abc-123", source: "qoder", state: .review, title: "x"))
        #expect(store.snapshot().actors.count == 1)
        store.clear(id: "qoder:abc-123")
        #expect(store.snapshot().actors.isEmpty)
    }

    @Test("the tick clears a finished row until the sender moves again")
    func acknowledge() {
        let dir = makeTempDir("ack")
        let store = ActorStore(
            directory: dir,
            seenDirectory: dir.appendingPathComponent("seen", isDirectory: true))
        let finished = Actor(
            id: "qoder:done", source: "qoder", state: .review, title: "完成",
            ttl: 20, updatedAt: Date(timeIntervalSinceNow: -2))
        store.publish(finished)
        #expect(store.snapshot().actors.count == 1)

        store.acknowledge(finished)
        #expect(store.snapshot().actors.isEmpty)
        // The acknowledgement is what keeps it away, not expiry.
        #expect(!finished.isExpired(at: Date()))

        // A newer state is a new fact, so the row returns on its own. Timestamps
        // are second-granular on disk, so the next event must land in a later one.
        var newer = finished
        newer.updatedAt = Date(timeIntervalSinceNow: 2)
        store.publish(newer)
        #expect(store.snapshot().actors.count == 1)
    }

    @Test("a tick for one actor leaves the others alone")
    func acknowledgeScoped() {
        let dir = makeTempDir("ack-scope")
        let store = ActorStore(
            directory: dir,
            seenDirectory: dir.appendingPathComponent("seen", isDirectory: true))
        let done = Actor(id: "a:done", source: "a", state: .review, title: "甲", ttl: 20)
        let busy = Actor(id: "b:busy", source: "b", state: .running, title: "乙", ttl: 180)
        store.publish(done)
        store.publish(busy)
        store.acknowledge(done)
        #expect(store.snapshot().actors.map(\.id) == [busy.id])
    }

    @Test("an undecodable file is skipped rather than fatal")
    func brokenFile() throws {
        let dir = makeTempDir("broken")
        try Data("{\"state\": not json".utf8)
            .write(to: dir.appendingPathComponent("broken.json"))
        let store = ActorStore(directory: dir)
        store.publish(Actor(id: "fine", source: "cli", state: .idle, title: "ok"))
        #expect(store.snapshot().actors.map { $0.id } == ["fine"])
    }

    @Test("ids are sanitised into one flat filename per actor")
    func fileNameSanitising() {
        #expect(Actor(id: "qoder:89e6/0c0e", source: "qoder", state: .idle, title: "x").fileName
            == "qoder-89e6-0c0e.json")
    }
}

@Suite("settings")
struct SettingsTests {
    @Test("choices round-trip through disk")
    func roundTrip() {
        let url = makeTempDir("settings").appendingPathComponent("settings.json")
        var settings = PetSettings()
        settings.petID = "rocky"
        settings.mascotWidth = 176
        settings.reduceMotion = true
        settings.save(to: url)
        #expect(PetSettings.load(from: url) == settings)
    }

    @Test("a missing file falls back to defaults")
    func defaults() {
        let loaded = PetSettings.load(from: URL(fileURLWithPath: "/nonexistent/settings.json"))
        #expect(loaded.petID == nil)
        #expect(loaded.mascotWidth == 128)
    }
}
