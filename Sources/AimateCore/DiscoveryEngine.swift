import Foundation

/// Runs every pull-mode adapter on a timer and mirrors their output into the
/// actor store, so push senders and observed agents share one rendering path.
public final class DiscoveryEngine {
    private let store: ActorStore
    private let adapters: [AgentAdapter]
    private var timer: Timer?
    private var published: [String: Actor] = [:]
    private let queue: DispatchQueue

    public init(store: ActorStore, adapters: [AgentAdapter], queue: DispatchQueue = .main) {
        self.store = store
        self.adapters = adapters
        self.queue = queue
    }

    public func start(interval: TimeInterval = 2) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    public func tick(now: Date = Date()) -> Int {
        var live: [String: Actor] = [:]
        for adapter in adapters {
            for actor in adapter.poll(now: now) { live[actor.id] = actor }
        }

        for (_, actor) in published where live[actor.id] == nil {
            store.clear(id: actor.id)
        }
        for (id, actor) in live where published[id] != actor {
            store.publish(actor)
        }
        published = live
        prune(live: live)
        return live.count
    }

    /// Orphan cleanup: if this process died earlier, its adapters never got to
    /// `clear`. Rendering already ignores those files, so only the disk needs tidying.
    /// The keep-set is what this engine reported *this tick* — reading the store back
    /// would let the renderer's own filters (a dead sender pid, say) delete actors
    /// that are perfectly current. Ownership is claimed by filename prefix, which
    /// means a push sender must keep out of `<source>:` ids: `ask:qoder:…` shares
    /// Qoder's badge but not its namespace, so the hook's question survives.
    private func prune(live: [String: Actor]) {
        let keep = Set(live.values.map { $0.fileName })
        let prefixes = adapters.map { $0.source + "-" }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: store.watchDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        for url in entries
        where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            if !keep.contains(url.lastPathComponent) { try? fm.removeItem(at: url) }
        }
    }
}
