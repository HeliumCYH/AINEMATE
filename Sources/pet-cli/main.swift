import AimateCore
import Foundation

/// Write-and-exit facade for the push channel. Any agent, hook script, or shell
/// one-liner can drive the pet with a single command that never stays running.
///
///   pet-cli push running --title "重构桌宠" --detail "swift build"
///   pet-cli push waiting --id build --ttl 300 --ask "要放行 rm 吗？"
///   pet-cli clear --id build
///   pet-cli list
let arguments = Array(CommandLine.arguments.dropFirst())

func value(of flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pet-cli: \(message)\n".utf8))
    exit(2)
}

func printUsage() {
    let usage = """
    用法:
      pet-cli push <idle|running|waiting|review|failed> [--id ID] [--source NAME]
                  [--title TEXT] [--detail TEXT] [--thread ID] [--ttl SECONDS] [--pid PID]
                  [--options 允许,拒绝]
      pet-cli reply --id ID [--timeout SECONDS]   # 阻塞直到桌宠上点了按钮，输出所选项
      pet-cli ask --source NAME --id ID [--title TEXT] [--detail TEXT] [--thread ID]
                  [--options 允许,拒绝] [--wait SECONDS]   # 发布问题并阻塞等待点击
      pet-cli hook qoder-permission   # 作为 Qoder PermissionRequest hook 使用（读 stdin）
      pet-cli bridge opencode   # 常驻：把 OpenCode 的待批准请求转发到桌宠并回写答案
      pet-cli clear [--id ID | --source NAME]
      pet-cli list
    """
    print(usage)
}

guard let command = arguments.first else {
    printUsage()
    exit(0)
}

let store = ActorStore()
let rest = Array(arguments.dropFirst())

/// Labels are capped because two of them have to fit a 232pt card.
func options(from raw: String?) -> [String]? {
    let parsed = raw?.split(separator: ",").compactMap { part -> String? in
        let label = part.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : String(label.prefix(12))
    } ?? []
    return parsed.isEmpty ? nil : parsed
}

/// Kill sources have to outlive the call that installed them.
var signalSources: [DispatchSourceSignal] = []

/// Publishes an ask, blocks until it is answered, then removes both files.
/// `nil` means "no answer", which every caller treats as "fall through to the
/// agent's own prompt" — never as consent.
func askAndWait(_ actor: Actor, waitSeconds: Double) -> String? {
    store.publish(actor)
    // A sender that dies mid-question must not leave the card behind, and the
    // handlers run off the main queue because the wait below blocks it.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let queue = DispatchQueue(label: "pet-cli.ask.signals")
    for number in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler {
            store.clear(id: actor.id)
            store.clearReply(for: actor.id)
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    let deadline = Date().addingTimeInterval(waitSeconds)
    while Date() < deadline {
        // A pet closed mid-question has nothing left to answer with, and making
        // the sender wait out the timeout would only add an invisible delay.
        guard store.petIsAlive() else { break }
        if let live = store.liveActors().first(where: { $0.id == actor.id }),
           let reply = store.reply(for: live) {
            store.clear(id: actor.id)
            store.clearReply(for: actor.id)
            return reply.option
        }
        usleep(200_000)
    }
    store.clear(id: actor.id)
    store.clearReply(for: actor.id)
    return nil
}

switch command {
case "push":
    guard let rawState = rest.first, let state = PetState(rawValue: rawState) else {
        fail("未知状态，可用：\(PetState.allCases.map { $0.rawValue }.joined(separator: ", "))")
    }
    let id = value(of: "--id", in: rest)
        ?? value(of: "--source", in: rest).map { "cli:\($0)" }
        ?? "cli"
    let source = value(of: "--source", in: rest) ?? "cli"
    let options = options(from: value(of: "--options", in: rest))
    let ttl = Double(value(of: "--ttl", in: rest) ?? "") ?? defaultTTL(for: state)
    // No pid on purpose: this process exits right after writing, so stamping it
    // would make the store's dead-sender rule drop the actor immediately.
    let pid = Int32(value(of: "--pid", in: rest) ?? "").map { Int($0) }
    store.publish(Actor(
        id: id,
        source: source,
        state: state,
        title: value(of: "--title", in: rest) ?? "未命名任务",
        detail: value(of: "--detail", in: rest) ?? value(of: "--ask", in: rest),
        thread: value(of: "--thread", in: rest),
        options: options,
        ttl: ttl,
        updatedAt: Date(),
        pid: pid))
    print("已推送 \(id) -> \(rawState)")

case "clear":
    if let id = value(of: "--id", in: rest) {
        store.clear(id: id)
        print("已清除 \(id)")
        break
    }
    if let source = value(of: "--source", in: rest) {
        let removed = store.liveActors().filter { $0.source == source }
        for actor in removed { store.clear(id: actor.id) }
        print("已清除 \(removed.count) 个 \(source) actor")
        break
    }
    fail("clear 需要 --id 或 --source")

case "list":
    let snapshot = store.snapshot()
    if snapshot.actors.isEmpty {
        print("（当前没有活着的 actor，桌宠处于 idle）")
        break
    }
    for actor in snapshot.actors {
        let age = Int(Date().timeIntervalSince(actor.updatedAt))
        print("\(actor.state.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))"
            + " [\(actor.source)] \(actor.title)"
            + "\(actor.detail.map { " — \($0)" } ?? "") (ttl \(Int(actor.ttl))s, \(age)s ago)")
    }

case "reply":
    guard let id = value(of: "--id", in: rest) else { fail("reply 需要 --id") }
    let timeout = Double(value(of: "--timeout", in: rest) ?? "") ?? 300
    let deadline = Date().addingTimeInterval(timeout)
    // Blocking poll is what lets a hook script gate a dangerous command on the pet:
    // `pet-cli push waiting --id x --options 允许,拒绝 && pet-cli reply --id x`.
    while Date() < deadline {
        if let actor = store.liveActors().first(where: { $0.id == id }),
           let reply = store.reply(for: actor) {
            print(reply.option)
            exit(0)
        }
        usleep(300_000)
    }
    FileHandle.standardError.write(Data("pet-cli: 等待回复超时（\(Int(timeout))s）\n".utf8))
    exit(3)

case "ask":
    // The one-shot contract every blocking sender shares: publish a question,
    // wait for a click, print the label. No output and exit 0 means "the pet did
    // not decide", so the caller keeps its own approval path.
    let source = value(of: "--source", in: rest) ?? "cli"
    let rawID = value(of: "--id", in: rest) ?? "ask"
    let waitSeconds = Double(value(of: "--wait", in: rest) ?? "") ?? 170
    let asked = Actor(
        // `ask:` belongs to no adapter, so the engine's prefix prune leaves it be.
        id: "ask:\(source):\(rawID)",
        source: source,
        state: .waiting,
        title: value(of: "--title", in: rest) ?? "\(Actor.agentName(for: source)) 请求批准",
        detail: value(of: "--detail", in: rest),
        thread: value(of: "--thread", in: rest),
        options: options(from: value(of: "--options", in: rest))
            ?? [QoderPermissionHook.allowOption, QoderPermissionHook.denyOption],
        ttl: waitSeconds + 30,
        updatedAt: Date(),
        pid: Int(ProcessInfo.processInfo.processIdentifier))
    guard store.petIsAlive() else { exit(0) }
    if let answer = askAndWait(asked, waitSeconds: waitSeconds) {
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    }
    exit(0)

case "bridge":
    guard rest.first == "opencode" else { fail("未知 bridge：\(rest.first ?? "")") }
    OpenCodeBridge.run(arguments: Array(rest.dropFirst()))

case "hook":
    // A PermissionRequest hook may only ever *add* an answer channel. Every path
    // here that cannot produce a verdict prints nothing and exits 0, which the
    // agent runtime reads as "no decision" and lets its own prompt stand — so a
    // closed pet, a weird payload or an unanswered ask all fall back untouched.
    guard rest.first == "qoder-permission" else { fail("未知 hook：\(rest.first ?? "")") }
    let payload = (try? JSONSerialization.jsonObject(
        with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any]
    guard let ask = payload.flatMap({ QoderPermissionHook.ask(for: $0) }) else { exit(0) }
    // An ask nobody can see is only a wait the user has to sit through.
    guard store.petIsAlive() else { exit(0) }
    let waitSeconds = Double(value(of: "--wait", in: rest) ?? "") ?? 170
    let asked = Actor(
        id: ask.actorID,
        source: "qoder",
        state: .waiting,
        title: ask.title,
        detail: ask.detail,
        thread: payload?["session_id"] as? String,
        options: QoderPermissionHook.options,
        ttl: waitSeconds + 30,
        updatedAt: Date(),
        // Stamping the sender means a cancelled turn or a killed hook drops the
        // card at once instead of leaving a question with no asker.
        pid: Int(ProcessInfo.processInfo.processIdentifier))
    if let answer = askAndWait(asked, waitSeconds: waitSeconds),
       let verdict = QoderPermissionHook.decision(forOption: answer) {
        FileHandle.standardOutput.write(verdict)
    }
    exit(0)

case "-h", "--help", "help":
    printUsage()

default:
    printUsage()
    fail("未知命令 \(command)")
}

func defaultTTL(for state: PetState) -> Double {
    switch state {
    case .idle: return 10
    case .running: return 180
    case .waiting: return 900
    case .review: return 90
    case .failed: return 180
    }
}
