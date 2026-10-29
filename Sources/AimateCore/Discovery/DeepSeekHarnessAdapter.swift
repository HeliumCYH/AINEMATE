import Foundation

/// The state snapshot DeepSeek Harness keeps per session.
///
/// `~/.dsh/storages/session_projcache/sessions/<id>.json` is the projection the
/// app's own UI reads. Harness rewrites it whenever the session log gains a
/// frame — on this machine the two files share a modification date — so it is a
/// plain-JSON view of a stream that is stored zstd-compressed, which is what a
/// resident pet app wants to avoid decoding 20 times a minute.
struct HarnessProjection: Decodable {
    let version: Int
    let record: Record

    struct Record: Decodable {
        let identity: Identity?
        let rows: [String: Row]?
    }

    struct Identity: Decodable {
        let formatVersion: Int?
        let createdAt: Double?
        let cwd: String?
    }

    struct Row: Decodable {
        let ver: Int?
        let seq: Int?
        let val: JSONValue?
    }

    var cwd: String? { record.identity?.cwd }

    private func value(_ row: String) -> JSONValue? {
        record.rows?[row]?.val
    }

    /// The session headline. `title` holds a bare string once the runtime has
    /// summarised the thread, and is `null` in a session that never got one.
    var title: String? { value("title")?.displayText }

    var goal: String? { value("goal")?["current"]?.displayText }

    var goalFailure: String? { value("goal")?["failure"]?.displayText }

    var hasOpenTurn: Bool {
        value("turnBoundary")?["openTurnStartSeq"]?.isPresent == true
    }

    var lastTurn: Int { value("turnBoundary")?["lastTurn"]?.intValue ?? 0 }

    var planActive: Bool { value("plan")?["active"]?.boolValue == true }

    var planStep: String? {
        value("plan")?["running"]?.displayText ?? value("plan")?["wanted"]?.displayText
    }

    /// `todos` is a flat array of `{content, status}` records.
    var todoProgress: (done: Int, total: Int)? {
        guard let todos = value("todos")?.arrayValue, !todos.isEmpty else { return nil }
        let done = todos.filter { Self.isDone($0["status"]?.stringValue) }.count
        return (done, todos.count)
    }

    static func isDone(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["completed", "complete", "done", "closed"].contains(status.lowercased())
    }

    /// A turn is on foot when its boundary is still open, or when the planner is
    /// mid-step. An outstanding approval is not visible in the projection, so
    /// `waiting` is deliberately never claimed from these rows.
    var derivedState: PetState {
        if let failure = goalFailure, !failure.isEmpty { return .failed }
        if hasOpenTurn || planActive { return .running }
        if lastTurn > 0 { return .review }
        return .idle
    }

    var derivedDetail: String? {
        if let failure = goalFailure, !failure.isEmpty { return ActorRules.trim(failure) }
        if let step = planStep, !step.isEmpty { return "计划进行中：\(ActorRules.trim(step))" }
        if let progress = todoProgress { return "任务 \(progress.done)/\(progress.total) 项完成" }
        if hasOpenTurn { return nil }
        if lastTurn > 0 { return "本轮结束，等你确认" }
        return nil
    }
}

/// The claim heartbeat the `aimate-pet` dsh plugin writes for the sessions it
/// forwards directly. While one is fresh, those sessions are that plugin's to
/// show: reading them from disk as well would put two cards on screen for one
/// turn, and the card would lose its tool line the moment the projection cache
/// lagged a frame behind the event stream.
public struct PluginClaim: Decodable, Equatable {
    public let pid: Int?
    public let at: Date
    public let sessions: [String]?

    /// Two beats plus slack: the plugin republishes every 5 s, and a slow tick
    /// must not hand a session back to this adapter mid-turn.
    public static let defaultGrace: TimeInterval = 15

    public func isFresh(at now: Date, grace: TimeInterval = defaultGrace) -> Bool {
        now.timeIntervalSince(at) <= grace
    }
}

/// Turns DeepSeek Harness's own session store into pet actors.
///
/// The desktop app and the `dsh` CLI share one root (`~/.dsh`) and one layout, so
/// a session created by either is observed the same way.
public final class DeepSeekHarnessAdapter: AgentAdapter {
    public let source = "dsh"

    private let root: URL
    private let activityWindow: TimeInterval
    private let claimDirectory: URL
    /// Parsed files keyed by mtime: the projection is rewritten whole, so a
    /// changed date means a changed snapshot and an unchanged one is free.
    private var cache: [String: (mtime: Date, projection: HarnessProjection)] = [:]
    private var claimCache: [String: (mtime: Date, claim: PluginClaim)] = [:]

    public init(root: URL = DeepSeekHarnessAdapter.defaultRoot(),
                activityWindow: TimeInterval? = nil,
                claimDirectory: URL? = nil) {
        self.root = root
        self.activityWindow = activityWindow ?? Self.defaultActivityWindow
        self.claimDirectory = claimDirectory ?? Self.defaultClaimDirectory()
    }

    public static func defaultRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = ProcessInfo.processInfo.environment["AIMATE_DSH_HOME"]
        return URL(fileURLWithPath: override ?? home.appendingPathComponent(".dsh").path,
                   isDirectory: true)
    }

    /// Beside the other pet files, so `AIMATE_HOME` moves the claims with the rest.
    public static func defaultClaimDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIMATE_DSH_CLAIMS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AimatePaths.petRoot
    }

    public func poll(now: Date) -> [Actor] {
        var actors: [Actor] = []
        let claimed = claimedSessions(now: now)
        for session in discoverSessions(now: now) where !claimed.contains(session.id) {
            guard let projection = projection(for: session) else { continue }
            guard let actor = ActorRules.actor(
                source: source, id: session.id, foldState: projection.derivedState,
                foldUpdated: session.mtime, now: now, activityWindow: activityWindow,
                title: projection.title ?? projection.goal
                    ?? ActorRules.directoryLabel(projection.cwd).map { "DeepSeek · \($0)" }
                    ?? "DeepSeek 会话",
                detail: projection.derivedDetail, pid: nil) else { continue }
            actors.append(actor)
        }
        return actors
    }

    // MARK: - Discovery

    struct Session {
        let id: String
        let mtime: Date
    }

    /// `<root>/sessions/<cwd-slug>/<uuid>/session.v3.jsonl.zstd`. The log's own
    /// timestamp is the liveness signal; the projection is read only for sessions
    /// that are still being written.
    private func discoverSessions(now: Date) -> [Session] {
        let fm = FileManager.default
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        guard let slugs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [Session] = []
        for slug in slugs {
            guard let ids = try? fm.contentsOfDirectory(
                at: slug, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for session in ids {
                let log = session.appendingPathComponent(Self.sessionLogName)
                guard let mtime = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { continue }
                guard now.timeIntervalSince(mtime) <= activityWindow else { continue }
                found.append(Session(id: session.lastPathComponent, mtime: mtime))
            }
        }
        return found.sorted { $0.mtime > $1.mtime }.prefix(Self.maxSessions).map { $0 }
    }

    static let sessionLogName = "session.v3.jsonl.zstd"
    static let maxSessions = 8
    static let defaultActivityWindow: TimeInterval = 900
    static let claimPrefix = "dsh-plugin-"

    /// Sessions some live plugin instance is forwarding. Read every poll because
    /// the claim is the hand-off: the moment it goes stale the disk view resumes.
    private func claimedSessions(now: Date) -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: claimDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var claimed: Set<String> = []
        for url in entries where url.lastPathComponent.hasPrefix(Self.claimPrefix)
            && url.pathExtension == "json" {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            let claim: PluginClaim
            if let hit = claimCache[url.path], hit.mtime == mtime {
                claim = hit.claim
            } else {
                guard let data = try? Data(contentsOf: url),
                      let parsed = try? Self.claimDecoder.decode(PluginClaim.self, from: data)
                else { continue }
                claimCache[url.path] = (mtime, parsed)
                claim = parsed
            }
            guard claim.isFresh(at: now) else { continue }
            // A heartbeat outlives a crash by its grace window; the pid closes
            // that window instead of leaving a dead host's sessions unobserved.
            if let pid = claim.pid, pid > 0, !ActorStore.isProcessAlive(pid) { continue }
            claimed.formUnion(claim.sessions ?? [])
        }
        return claimed
    }

    private static let claimDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func projection(for session: Session) -> HarnessProjection? {
        let url = root
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
            .appendingPathComponent(session.id + ".json")
        // Validated against the projection's own date, not the log's: they move
        // together in practice, but a lagging cache must not serve a stale state.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let hit = cache[session.id], hit.mtime == mtime { return hit.projection }
        guard let data = try? Data(contentsOf: url),
              let projection = try? JSONDecoder().decode(HarnessProjection.self, from: data)
        else { return nil }
        cache[session.id] = (mtime, projection)
        return projection
    }
}
