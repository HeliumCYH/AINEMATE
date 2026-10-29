import CoreServices
import Foundation

/// Coalesced filesystem notification for one directory, so a `pet-cli` push
/// shows up in the same second instead of on the next poll tick.
public final class DirectoryEventStream {
    private var stream: FSEventStreamRef?
    private var context: Context?
    private let callback: @Sendable () -> Void
    private let latency: TimeInterval

    /// Passed to FSEvents as the `info` pointer; retained for the stream's life.
    private final class Context: @unchecked Sendable {
        let callback: @Sendable () -> Void
        init(callback: @escaping @Sendable () -> Void) { self.callback = callback }
    }

    public init(latency: TimeInterval = 0.15, onEvent: @escaping @Sendable () -> Void) {
        self.latency = latency
        self.callback = onEvent
    }

    deinit { stop() }

    public func start(directory: URL) {
        guard stream == nil else { return }
        AimatePaths.ensureDirectories()
        let ctx = Context(callback: callback)
        context = ctx

        var schema = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(ctx).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, _, _, _, _) in
                guard let info else { return }
                Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().callback()
            },
            &schema,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.context = nil
    }
}
