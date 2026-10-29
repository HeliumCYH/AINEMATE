import Foundation

/// Turns Qoder CN's own per-session event log into pet actors.
///
/// Qoder already appends a JSONL stream for every conversation, so this adapter
/// is pure observation: no hooks to install, no per-session start, nothing for
/// the user to remember. A conversation that begins while the pet is running is
/// picked up on the next poll.
public final class QoderAdapter: AgentAdapter {
    public let source = "qoder"

    /// Qoder summarizes every task in a hidden conversation of its own, opened
    /// with this fixed preamble. That conversation carries no is_meta or
    /// is_subagent mark, so the prompt text is the only thing that tells it apart
    /// from a session the user started.
    static let recapPreamble = "你正在为 Qoder 任务监控编写简短的会话 Recap"

    private var sessionsRoot: URL
    private let activityWindow: TimeInterval = 900
    private let tailer = JSONLTailer()
    private var folds: [String: SessionFold] = [:]

    public init(sessionsRoot: URL = QoderAdapter.defaultSessionsRoot()) {
        self.sessionsRoot = sessionsRoot
    }

    public static func defaultSessionsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = ProcessInfo.processInfo.environment["AIMATE_QODER_LOGS"]
        if let override { return URL(fileURLWithPath: override, isDirectory: true) }
        return home.appendingPathComponent(".qoder-cn/logs/sessions", isDirectory: true)
    }

    struct SessionFold {
        var state: PetState = .idle
        var title: String?
        var detail: String?
        var pendingApprovals: Set<String> = []
        var updatedAt: Date = .distantPast
        var pid: Int?
        var isInternal = false
    }

    public func poll(now: Date) -> [Actor] {
        var actors: [Actor] = []
        for session in discoverSessions(now: now) {
            if let actor = actor(for: session, now: now) { actors.append(actor) }
        }
        return actors
    }

    // MARK: - Discovery

    private struct SessionLog {
        let id: String
        let project: String
        let segment: URL
        /// The conversation folder is created when the session starts, which is
        /// older than the newest run segment for a resumed conversation.
        let started: Date?
    }

    /// `<root>/<project>/<session>/segments/<run-id>.jsonl`, newest segment only.
    /// The run id embeds `-p<pid>`, which lets the store retire actors the moment
    /// their worker process is gone.
    private func discoverSessions(now: Date) -> [SessionLog] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [SessionLog] = []
        for project in projects {
            guard let sessions = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for session in sessions {
                let segmentsURL = session.appendingPathComponent("segments", isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(
                    at: segmentsURL, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { continue }

                let recent = files
                    .filter { $0.pathExtension == "jsonl" }
                    .filter { url in
                        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        return now.timeIntervalSince(mtime) <= activityWindow
                    }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                guard let newest = recent.first else { continue }
                found.append(SessionLog(
                    id: session.lastPathComponent,
                    project: project.lastPathComponent,
                    segment: newest,
                    started: (try? session.resourceValues(forKeys: [.creationDateKey]))?
                        .creationDate))
            }
        }
        return found
    }

    // MARK: - Fold

    private func actor(for session: SessionLog, now: Date) -> Actor? {
        guard let lines = tailer.readLines(from: session.segment) else {
            return existingActor(for: session, fold: folds[session.id], now: now)
        }
        var fold = folds[session.id] ?? SessionFold(pid: Self.pid(from: session.segment))
        // A restarted Qoder opens a new run id for the same session, so the pid has
        // to follow the segment: an actor still naming the previous worker is read
        // as a dead sender and dropped, which blanks the pet.
        if let pid = Self.pid(from: session.segment), pid != fold.pid { fold.pid = pid }
        for line in lines { fold.apply(json: line) }
        folds[session.id] = fold
        return existingActor(for: session, fold: fold, now: now)
    }

    private func existingActor(for session: SessionLog, fold: SessionFold?, now: Date) -> Actor? {
        guard let fold, !fold.isInternal else { return nil }
        return ActorRules.actor(
            source: source, id: session.id, foldState: fold.state, foldUpdated: fold.updatedAt,
            now: now, activityWindow: activityWindow,
            title: fold.title ?? Self.fallbackTitle(project: session.project, session: session.id),
            detail: fold.detail, pid: fold.pid, startedAt: session.started)
    }

    /// Run ids look like `2026-10-28T19-42-27-569+08-00-g4uyeh-p59656`.
    static func pid(from segment: URL) -> Int? {
        let name = segment.deletingPathExtension().lastPathComponent
        guard let marker = name.range(of: "-p", options: .backwards) else { return nil }
        let tail = String(name[marker.upperBound...])
        return Int(tail.filter { $0.isNumber })
    }

    static func fallbackTitle(project: String, session: String) -> String {
        project == "-" ? "Qoder 会话" : "Qoder · \(shortProject(project))"
    }

    static func shortProject(_ project: String) -> String {
        let parts = project.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? project
    }
}

private extension QoderAdapter.SessionFold {
    /// Only events that move the state machine stamp the actor; Qoder's noisy
    /// phase/hook records must not keep a finished turn alive.
    mutating func apply(json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(QoderEvent.self, from: data),
              let at = event.date else { return }
        let payload = event.data ?? QoderEvent.Payload()
        var recognised = true

        switch event.type {
        case "input.prompt.submitted":
            if payload.isSubagent != true, payload.isMeta != true,
               let preview = payload.textPreview, !preview.isEmpty {
                if preview.hasPrefix(QoderAdapter.recapPreamble) {
                    // The recap conversation is Qoder's own bookkeeping. Hiding the
                    // whole session matters more than hiding its title: its end_turn
                    // review outranks the real task's running state and takes the card.
                    isInternal = true
                } else {
                    title = ActorRules.trim(preview)
                }
            }
            noteActivity(detail: nil)

        case "turn.started", "model.request.started", "tool.shell.started":
            noteActivity(detail: nil)

        case "tool.requested":
            noteActivity(detail: payload.toolName.map { "正在调用 \($0)" })

        case "tool.execution.finished":
            noteActivity(detail: payload.status == "denied"
                ? payload.toolName.map { "\($0) 被拒绝" } : nil)

        case "permission.requested":
            if let call = event.toolCallId { pendingApprovals.insert(call) }
            detail = payload.askMessage ?? payload.toolName.map { "等待批准：\($0)" }
            state = .waiting

        case "permission.resolved":
            if let call = event.toolCallId { pendingApprovals.remove(call) }
            if pendingApprovals.isEmpty {
                noteActivity(detail: payload.allowed == false ? "已拒绝，继续中" : nil)
            }

        case "fork.agent.started":
            noteActivity(detail: payload.forkLabel == "compact" ? "正在压缩上下文" : nil)

        case "turn.finished":
            finish(reason: payload.reason, error: payload.error, durationMs: payload.durationMs)

        default:
            recognised = false
        }

        if recognised { updatedAt = at }
    }

    /// Activity refreshes the actor, but never over-shadows an unanswered
    /// approval: the pet keeps asking until the agent actually moves on.
    mutating func noteActivity(detail newDetail: String?) {
        guard !(state == .waiting && !pendingApprovals.isEmpty) else { return }
        // A turn that starts after an outcome must not inherit its line, or the
        // card reads "工作中 · 用时 32 秒" for work that just began.
        if let newDetail {
            detail = newDetail
        } else if state != .running {
            detail = nil
        }
        state = .running
    }

    mutating func finish(reason: String?, error: String?, durationMs: Int?) {
        pendingApprovals.removeAll()
        switch reason {
        case "end_turn":
            detail = durationMs.map { "用时 \(ActorRules.humanDuration($0))" } ?? "已完成"
            state = .review
        case "max_turns":
            detail = "上下文轮次用完，需要你继续"
            state = .waiting
        case "error":
            detail = error.map { ActorRules.trim($0) } ?? "运行出错"
            state = .failed
        default:
            state = .idle
            detail = nil
        }
    }

}
