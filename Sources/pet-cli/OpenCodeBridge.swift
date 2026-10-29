import AimateCore
import Foundation

/// Answers OpenCode's approval questions from the pet.
///
/// OpenCode never writes a pending ask to disk, so the only seam is the local API
/// its own approval panel calls: list what is pending, then reply to one. The
/// bridge polls instead of subscribing because the list is tiny, the round trip
/// is local, and a poll has no reconnect logic to get wrong.
///
/// Permissions belong to a location (a directory), so the bridge asks about every
/// directory with a recently active session — not just the server's own default,
/// which would miss every project except the one OpenCode was launched in.
enum OpenCodeBridge {
    private final class Context {
        var stateFile = OpenCodePermission.stateFile()
        var databasePath = OpenCodeAdapter.defaultDatabase().path
        var pidFile = AimatePaths.petRoot.appendingPathComponent("bridge-opencode.pid")
        var interval: TimeInterval = 0.7
        var ticks = Int.max
        var url: String?
        var password: String?
        var verbose = ProcessInfo.processInfo.environment["AIMATE_BRIDGE_LOG"] != nil
    }

    static func run(arguments: [String]) -> Never {
        let context = Context()
        if let flag = value(of: "--url", in: arguments) { context.url = flag }
        if let flag = value(of: "--password", in: arguments) { context.password = flag }
        if let flag = value(of: "--state", in: arguments) {
            context.stateFile = URL(fileURLWithPath: flag)
        }
        if let flag = value(of: "--pid-file", in: arguments) {
            context.pidFile = URL(fileURLWithPath: flag)
        }
        if let flag = value(of: "--interval", in: arguments), let seconds = Double(flag) {
            context.interval = max(0.1, seconds)
        }
        if let flag = value(of: "--ticks", in: arguments), let count = Int(flag) {
            context.ticks = max(1, count)
        }
        if arguments.contains("--verbose") { context.verbose = true }

        let bridge = Bridge(context: context)
        bridge.start()
    }

    /// One poller. Kept as a class because the signal handler needs to clear the
    /// cards it published, and those live across ticks.
    private final class Bridge {
        private let context: Context
        private let store = ActorStore()
        private var published: [String: Actor] = [:]
        private var answered: Set<String> = []
        private var failures = 0
        private let selfPID = Int(ProcessInfo.processInfo.processIdentifier)

        init(context: Context) { self.context = context }

        func start() -> Never {
            AimatePaths.ensureDirectories()
            // Two pets (or a relaunch that raced the old bridge) must not fight
            // over the same cards.
            if let other = readPID(context.pidFile), other != selfPID,
               kill(pid_t(other), 0) == 0 || errno == EPERM {
                log("already running as \(other)")
                exit(0)
            }
            try? Data("\(selfPID)".utf8).write(to: context.pidFile, options: .atomic)
            installSignals()
            log("watching \(context.stateFile.path)")
            var tick = 0
            while tick < context.ticks {
                poll()
                tick += 1
                usleep(useconds_t(context.interval * 1_000_000))
            }
            shutdown()
        }

        // MARK: - One tick

        private func poll() {
            guard let service = resolveService() else {
                clearAll("no opencode service")
                return
            }
            guard let fresh = pending(service) else {
                // A brief outage should not make every card blink; a long one
                // means the server is gone and the questions with it.
                failures += 1
                if failures >= Self.failureLimit { clearAll("server unreachable") }
                return
            }
            failures = 0

            let freshIDs = Set(fresh.map(OpenCodePermission.actorID(for:)))
            for request in fresh {
                let id = OpenCodePermission.actorID(for: request)
                if answered.contains(id) { continue }
                if published[id] != nil {
                    // Read the card back rather than trusting the in-memory copy:
                    // `updatedAt` on disk is truncated to whole seconds, and a
                    // reply written in the same second would look older than a
                    // sub-second in-memory stamp and be dropped as stale.
                    if let live = store.liveActors().first(where: { $0.id == id }),
                       let reply = store.reply(for: live) {
                        answer(service, request, reply.option)
                    }
                } else {
                    publish(request)
                }
            }
            for id in published.keys where !freshIDs.contains(id) {
                guard let actor = published[id] else { continue }
                store.clear(id: id)
                store.clearReply(for: id)
                published[id] = nil
                answered.remove(id)
                log("gone \(actor.title)")
            }
        }

        private func resolveService() -> OpenCodePermission.Service? {
            let service: OpenCodePermission.Service?
            if let url = context.url, let password = context.password {
                service = OpenCodePermission.Service(url: url, password: password)
            } else {
                service = OpenCodePermission.service(from: context.stateFile)
            }
            guard let service, OpenCodePermission.isRunning(service) else { return nil }
            return service
        }

        /// `nil` only when the server could not be asked at all, which is a very
        /// different state from "nothing is pending".
        private func pending(_ service: OpenCodePermission.Service) -> [OpenCodePermission.Request]? {
            let directories = [nil] + OpenCodeLocations.active(databasePath: context.databasePath)
            var seen: Set<String> = []
            var result: [OpenCodePermission.Request] = []
            var reachable = false
            for directory in directories {
                guard let batch = list(service, directory: directory) else { continue }
                reachable = true
                for request in batch where seen.insert(OpenCodePermission.actorID(for: request)).inserted {
                    result.append(request)
                }
            }
            return reachable ? result : nil
        }

        private func list(
            _ service: OpenCodePermission.Service, directory: String?
        ) -> [OpenCodePermission.Request]? {
            guard let url = OpenCodePermission.pendingURL(service, directory: directory) else { return nil }
            let (status, data) = http(url, method: "GET", auth: OpenCodePermission.authorization(service))
            guard status == 200, let data,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                return nil
            }
            return envelope.data
        }

        // MARK: - Cards

        private func publish(_ request: OpenCodePermission.Request) {
            let id = OpenCodePermission.actorID(for: request)
            let actor = Actor(
                id: id,
                source: "opencode",
                state: .waiting,
                title: OpenCodePermission.title(for: request),
                detail: OpenCodePermission.detail(for: request),
                thread: request.sessionID,
                options: OpenCodePermission.options,
                // Long enough to outlive a slow human, and stamped with this
                // process so a dead bridge takes its questions with it.
                ttl: 1800,
                updatedAt: Date(),
                pid: selfPID)
            store.publish(actor)
            published[id] = actor
            log("asked \(actor.title)")
        }

        private func answer(
            _ service: OpenCodePermission.Service, _ request: OpenCodePermission.Request, _ option: String
        ) {
            let id = OpenCodePermission.actorID(for: request)
            guard let body = OpenCodePermission.replyBody(forOption: option),
                  let url = OpenCodePermission.replyURL(service, request: request) else {
                answered.insert(id)
                store.clear(id: id)
                return
            }
            let (status, _) = http(
                url, method: "POST", auth: OpenCodePermission.authorization(service), body: body)
            // 404 means someone answered in OpenCode's own window first; either
            // way the question is settled and the card must go.
            guard status == 204 || status == 404 else {
                log("reply failed (\(status)) for \(id)")
                return
            }
            answered.insert(id)
            published[id] = nil
            store.clear(id: id)
            store.clearReply(for: id)
            log("answered \(option) -> \(id)")
        }

        /// Cards are keyed by the actor id, so only ones this process published
        /// can be cleared here.
        private func clearAll(_ reason: String) {
            guard !published.isEmpty else { return }
            log("clearing (\(reason))")
            for id in published.keys {
                store.clear(id: id)
                store.clearReply(for: id)
            }
            published.removeAll()
            answered.removeAll()
        }

        // MARK: - Plumbing

        private static let failureLimit = 15

        private func installSignals() {
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let queue = DispatchQueue(label: "pet-cli.bridge.signals")
            for number in [SIGTERM, SIGINT] {
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self else { exit(0) }
                    self.clearAll("terminated")
                    try? FileManager.default.removeItem(at: self.context.pidFile)
                    exit(0)
                }
                source.resume()
                signalSources.append(source)
            }
        }

        func shutdown() -> Never {
            clearAll("stopped")
            try? FileManager.default.removeItem(at: context.pidFile)
            exit(0)
        }

        private func readPID(_ url: URL) -> Int? {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private func log(_ message: String) {
            guard context.verbose else { return }
            FileHandle.standardError.write(Data("bridge opencode: \(message)\n".utf8))
        }

        /// Synchronous on purpose: the loop is a poll, and an async hop would only
        /// add state to reason about.
        private func http(
            _ url: URL, method: String, auth: String, body: Data? = nil
        ) -> (Int, Data?) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 2.5
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var status = 0
            var payload: Data?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                payload = data
                done.signal()
            }.resume()
            done.wait()
            return (status, payload)
        }
    }

    private struct Envelope: Decodable {
        let data: [OpenCodePermission.Request]
    }
}
