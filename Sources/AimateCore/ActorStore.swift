import Foundation

/// A row the user has cleared by hand. Stored next to the replies so the whole
/// pet state keeps living under one directory.
public struct ActorAck: Codable, Equatable, Sendable {
    public let actorId: String
    public let at: Date

    public init(actorId: String, at: Date) {
        self.actorId = actorId
        self.at = at
    }
}

/// File-backed actor store. `~/.aimate/pet/actors/*.json` is the single contract:
/// anything that can write a file can drive the pet, and the app never needs to
/// trust the sender to clean up after itself.
public final class ActorStore {
    private let directory: URL
    private let repliesDirectory: URL
    private let seenDirectory: URL
    private let heartbeatFile: URL
    private let queue = DispatchQueue(label: "com.aimate.pet.actor-store")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL = AimatePaths.actorsDir,
                repliesDirectory: URL = AimatePaths.repliesDir,
                seenDirectory: URL = AimatePaths.seenDir,
                heartbeatFile: URL = AimatePaths.heartbeatFile) {
        self.directory = directory
        self.repliesDirectory = repliesDirectory
        self.seenDirectory = seenDirectory
        self.heartbeatFile = heartbeatFile
    }

    public var watchDirectory: URL { directory }

    /// The pet touches this on every tick; an asker uses it to decide whether an
    /// answer is reachable at all before it starts waiting.
    public func markAlive(now: Date = Date()) {
        AimatePaths.ensureDirectories()
        try? Data(String(Int(now.timeIntervalSince1970)).utf8)
            .write(to: heartbeatFile, options: [.atomic])
    }

    /// Fresh within `grace`, which is deliberately generous against a throttled
    /// timer: a pet that merely stalled a second should still take the ask.
    public func petIsAlive(now: Date = Date(), grace: TimeInterval = 6) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: heartbeatFile.path),
              let written = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(written) <= grace
    }

    public func publish(_ actor: Actor) {
        AimatePaths.ensureDirectories()
        let url = directory.appendingPathComponent(actor.fileName)
        guard let data = try? encoder.encode(actor) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    public func clear(id: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(Actor.fileName(for: id)))
    }

    public func record(_ reply: ActorReply) {
        AimatePaths.ensureDirectories()
        let url = repliesDirectory.appendingPathComponent(Actor.fileName(for: reply.actorId))
        guard let data = try? encoder.encode(reply) else { return }
        try? FileManager.default.createDirectory(at: repliesDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    /// The answer already given for this actor, if any. A sender that re-publishes
    /// the same id with a newer `updatedAt` is asking again, so the stale reply is
    /// reported as absent rather than replayed.
    public func reply(for actor: Actor, now: Date = Date()) -> ActorReply? {
        let url = repliesDirectory.appendingPathComponent(actor.fileName)
        guard let data = FileManager.default.contents(atPath: url.path),
              let reply = try? decoder.decode(ActorReply.self, from: data),
              reply.actorId == actor.id, reply.at >= actor.updatedAt else { return nil }
        return reply
    }

    public func clearReply(for actorId: String) {
        try? FileManager.default.removeItem(
            at: repliesDirectory.appendingPathComponent(Actor.fileName(for: actorId)))
    }

    /// The user's own "I have seen it". A sender knows nothing about this; the
    /// mark only suppresses the row until the sender publishes something newer.
    public func acknowledge(_ actor: Actor, now: Date = Date()) {
        let url = seenDirectory.appendingPathComponent(actor.fileName)
        guard let data = try? encoder.encode(ActorAck(actorId: actor.id, at: now)) else { return }
        try? FileManager.default.createDirectory(
            at: seenDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    func isAcknowledged(_ actor: Actor) -> Bool {
        let url = seenDirectory.appendingPathComponent(actor.fileName)
        guard let data = FileManager.default.contents(atPath: url.path),
              let ack = try? decoder.decode(ActorAck.self, from: data),
              ack.actorId == actor.id else { return false }
        // A newer `updatedAt` is a new turn, so the old acknowledgement expires
        // with the state it referred to.
        return ack.at >= actor.updatedAt
    }

    /// Live actors, expired ones dropped. A file that cannot be decoded is
    /// ignored rather than fatal: a half-written actor must not kill the pet.
    public func snapshot(now: Date = Date()) -> ActorSnapshot {
        ActorSnapshot(actors: liveActors(now: now))
    }

    public func liveActors(now: Date = Date()) -> [Actor] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var result: [Actor] = []
        result.reserveCapacity(entries.count)
        for url in entries where url.pathExtension == "json" {
            guard let data = fm.contents(atPath: url.path),
                  let actor = try? decoder.decode(Actor.self, from: data),
                  !actor.isExpired(at: now) else { continue }
            if let pid = actor.pid, pid > 0, !Self.isProcessAlive(pid) { continue }
            if isAcknowledged(actor) { continue }
            result.append(actor)
        }
        return result
    }

    /// A dead sender with a long TTL should not keep the pet busy.
    static func isProcessAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
