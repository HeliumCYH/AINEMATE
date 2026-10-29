import Foundation

/// One record from `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`.
///
/// `payload` is a different shape per `type` and per event name, so every member
/// is optional and unknown names simply fail to bind — the adapter degrades to
/// "something happened" instead of throwing records away.
struct CodexRecord: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        // event_msg discriminator, e.g. `task_started`, `task_complete`.
        let type: String?
        let turnId: String?
        let message: String?
        let lastAgentMessage: String?
        let command: String?
        let reason: String?
        let error: String?
        // session_meta
        let sessionId: String?
        let cwd: String?
        let originator: String?
        // response_item message
        let role: String?

        enum CodingKeys: String, CodingKey {
            case type, message, command, reason, error, role, cwd, originator
            case turnId = "turn_id"
            case lastAgentMessage = "last_agent_message"
            case sessionId = "session_id"
        }
    }

    var date: Date? {
        guard let timestamp else { return nil }
        return CodexRecord.dateParser.date(from: timestamp)
    }

    /// Codex writes UTC with a trailing `Z` and millisecond precision.
    static let dateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let fallbackDateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension CodexRecord {
    var recordDate: Date? {
        date ?? timestamp.flatMap { CodexRecord.fallbackDateParser.date(from: $0) }
    }
}

/// Turns Codex's own rollout log into pet actors.
///
/// The desktop app and the CLI write the same tree — the rollout's `session_meta`
/// carries `originator: "Codex Desktop"` and `source: "vscode"` for the app, and
/// the CLI writes the identical schema — so one adapter covers both, and a thread
/// started in either appears without any setup.
public final class CodexAdapter: AgentAdapter {
    public let source = "codex"

    private let sessionsRoot: URL
    private let indexURL: URL
    private let activityWindow: TimeInterval
    private let tailer = JSONLTailer()
    private var folds: [String: Fold] = [:]
    private var indexCache: (mtime: Date, titles: [String: String])?

    public init(
        codexRoot: URL = CodexAdapter.defaultRoot(),
        activityWindow: TimeInterval? = nil
    ) {
        self.sessionsRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        self.indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        self.activityWindow = activityWindow ?? Self.defaultActivityWindow
    }

    public static func defaultRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = ProcessInfo.processInfo.environment["AIMATE_CODEX_HOME"]
        return URL(fileURLWithPath: override ?? home.appendingPathComponent(".codex").path,
                   isDirectory: true)
    }

    struct Fold {
        var state: PetState = .idle
        var prompt: String?
        var detail: String?
        var cwd: String?
        var originator: String?
        var openTurnId: String?
        var updatedAt: Date = .distantPast
    }

    public func poll(now: Date) -> [Actor] {
        let titles = readIndex()
        var actors: [Actor] = []
        for rollout in discoverRollouts(now: now) {
            guard let fold = fold(for: rollout, now: now) else { continue }
            let id = Self.sessionID(from: rollout.url)
            guard let actor = ActorRules.actor(
                source: source, id: id, foldState: fold.state, foldUpdated: fold.updatedAt,
                now: now, activityWindow: activityWindow,
                title: titles[id] ?? fold.prompt
                    ?? ActorRules.directoryLabel(fold.cwd).map { "Codex · \($0)" }
                    ?? "Codex 会话",
                detail: fold.detail, pid: nil) else { continue }
            actors.append(actor)
        }
        return actors
    }

    // MARK: - Discovery

    struct Rollout {
        let url: URL
        let mtime: Date
    }

    /// Rollout files are append-only and never rewritten, so only the newest few
    /// can belong to a live turn. The date directories are named from the local
    /// calendar, so the candidate days are derived rather than walked: pruning by
    /// directory mtime would miss a thread that started yesterday and is still
    /// running, because appending to a file does not touch its directory.
    private func discoverRollouts(now: Date) -> [Rollout] {
        var found: [Rollout] = []
        for day in candidateDays(now: now) {
            found.append(contentsOf: rollouts(in: day, now: now))
        }
        return found.sorted { $0.mtime > $1.mtime }.prefix(Self.maxRollouts).map { $0 }
    }

    static let lookbackDays = 3

    private func candidateDays(now: Date) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        return (0...Self.lookbackDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return sessionsRoot
                .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
                .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
                .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
        }
    }

    private func rollouts(in day: URL, now: Date) -> [Rollout] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: day, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout") else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(mtime) <= activityWindow else { return nil }
            return Rollout(url: url, mtime: mtime)
        }
    }

    static let maxRollouts = 8
    static let defaultActivityWindow: TimeInterval = 900

    /// `rollout-2026-07-12T13-11-17-019f54bc-a5d4-7300-80e4-218022192fa9.jsonl`
    /// keeps its UUID in the tail; the timestamp prefix is only when the thread
    /// started, so it must not become part of the identity.
    static func sessionID(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let stripped = stem.hasPrefix("rollout-") ? String(stem.dropFirst("rollout-".count)) : stem
        if stripped.count >= 36 {
            let candidate = String(stripped.suffix(36))
            if candidate.filter({ $0 == "-" }).count == 4 { return candidate }
        }
        return stripped
    }

    // MARK: - Fold

    private func fold(for rollout: Rollout, now: Date) -> Fold? {
        let id = Self.sessionID(from: rollout.url)
        var fold = folds[id] ?? Fold()
        if let lines = tailer.readLines(from: rollout.url) {
            for line in lines { fold.apply(record: line, now: now) }
        }
        // The fold is stored even when it produced nothing: the tailer has already
        // moved past these lines, and dropping the fold would lose them for good.
        folds[id] = fold
        // A rollout with no recognised event tells us nothing about a live turn;
        // seeding from its mtime alone would resurrect a thread that ended hours ago.
        return fold.updatedAt == .distantPast ? nil : fold
    }

    /// `~/.codex/session_index.jsonl` holds Codex's own summarised thread titles.
    /// Re-read only when the file changed: it grows with the whole thread history.
    private func readIndex() -> [String: String] {
        guard let mtime = (try? indexURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return [:] }
        if let cache = indexCache, cache.mtime == mtime { return cache.titles }
        var titles: [String: String] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let record = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(ThreadIndexEntry.self, from: record),
                      let id = entry.id, let name = entry.threadName, !name.isEmpty else { continue }
                titles[id] = ActorRules.trim(name)
            }
        }
        indexCache = (mtime, titles)
        return titles
    }

    private struct ThreadIndexEntry: Decodable {
        let id: String?
        let threadName: String?
        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }
}

private extension CodexAdapter.Fold {
    /// Only events that move the state machine stamp `updatedAt`; `token_count`
    /// and `thread_settings_applied` arrive on every turn and would keep a
    /// finished thread alive forever.
    mutating func apply(record json: String, now: Date) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(CodexRecord.self, from: data) else { return }
        let at = event.recordDate ?? now
        let payload = event.payload
        var recognised = true

        switch event.type {
        case "session_meta":
            cwd = payload?.cwd ?? cwd
            originator = payload?.originator ?? originator

        case "event_msg":
            apply(event: payload?.type, payload: payload)

        case "response_item":
            // The user prompt also appears as a response item; the `event_msg`
            // copy is preferred, so this only backstops a missing one.
            if payload?.role == "user", prompt == nil, let text = payload?.message {
                prompt = ActorRules.trim(text)
            }

        default:
            recognised = false
        }

        if recognised { updatedAt = max(updatedAt, at) }
    }

    mutating func apply(event name: String?, payload: CodexRecord.Payload?) {
        switch name {
        case "task_started":
            openTurnId = payload?.turnId
            detail = nil
            state = .running

        case "user_message":
            if let message = payload?.message, !message.isEmpty {
                prompt = ActorRules.trim(message)
            }
            state = .running

        case "agent_message", "agent_reasoning":
            detail = name == "agent_reasoning" ? "正在思考" : "正在回复"
            state = .running

        case "exec_command_begin", "patch_apply_begin":
            detail = Self.toolDetail(name: name, payload: payload)
            state = .running

        case "exec_approval_request", "apply_patch_approval_request", "request_permissions":
            detail = payload?.command.map { "等待批准：\(ActorRules.trim($0))" } ?? "等待你的批准"
            state = .waiting

        case "task_complete":
            openTurnId = nil
            detail = payload?.lastAgentMessage.map { ActorRules.trim($0) } ?? "已完成，等你确认"
            state = .review

        case "turn_aborted":
            openTurnId = nil
            detail = payload?.reason.map { ActorRules.trim($0) } ?? "已中断"
            state = .idle

        default:
            // Unknown event names are ignored rather than trusted: guessing
            // "running" from a record we cannot read would keep dead threads live.
            if let kind = name, kind.contains("error") {
                detail = payload?.error.map { ActorRules.trim($0) } ?? "运行出错"
                state = .failed
            }
        }
    }

    static func toolDetail(name: String?, payload: CodexRecord.Payload?) -> String {
        if name == "patch_apply_begin" { return "正在修改文件" }
        return payload?.command.map { "正在执行 \(ActorRules.trim($0))" } ?? "正在执行命令"
    }
}

extension ActorRules {
    /// Shared gate: an actor only survives while its state is worth showing and
    /// its last event is recent enough to belong to a live turn.
    static func actor(
        source: String,
        id: String,
        foldState: PetState,
        foldUpdated: Date,
        now: Date,
        activityWindow: TimeInterval,
        title: String,
        detail: String?,
        pid: Int?,
        startedAt: Date? = nil
    ) -> Actor? {
        guard foldState != .idle else { return nil }
        // A turn that is inside one long model call or shell command writes
        // nothing for minutes (7 and 10 minute stretches in real Qoder logs), so
        // the 3 minute running ttl blanked the pet mid-task. A live worker pid
        // says the sender still owns the turn; the activity window keeps a
        // forgotten turn from reading as busy forever.
        let window = foldState == .running && (pid.map { ActorStore.isProcessAlive($0) } ?? false)
            ? activityWindow
            : ttl(for: foldState)
        guard foldUpdated != .distantPast,
              now.timeIntervalSince(foldUpdated) <= window,
              now.timeIntervalSince(foldUpdated) <= activityWindow else { return nil }
        return Actor(
            id: "\(source):\(id)",
            source: source,
            state: foldState,
            title: title,
            detail: detail,
            thread: id,
            ttl: window,
            updatedAt: foldUpdated,
            startedAt: startedAt,
            pid: pid)
    }
}
