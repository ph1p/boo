import CoreServices
import Foundation

/// Watches a directory for file system changes using FSEvents.
final class FileSystemWatcher: @unchecked Sendable {
    /// FSEvents callbacks run here, off the main thread: a build or install can
    /// report thousands of paths, and filtering them on main stalls typing.
    /// Only the filtered batch hops to main.
    private static let queue = DispatchQueue(label: "boo.fs-watcher", qos: .utility)

    /// What the callback needs, owned by the stream rather than the watcher, so
    /// a callback in flight never points at a watcher that is being freed.
    private final class Handler: @unchecked Sendable {
        let filter: ((String) -> Bool)?
        let onChange: ([String]) -> Void
        let onRootChanged: (() -> Void)?
        /// Cleared by stop() on main; read on main before delivering, so a batch
        /// already queued when the watcher stops is dropped.
        var active = true

        init(filter: ((String) -> Bool)?, onChange: @escaping ([String]) -> Void, onRootChanged: (() -> Void)?) {
            self.filter = filter
            self.onChange = onChange
            self.onRootChanged = onRootChanged
        }
    }

    private var stream: FSEventStreamRef?
    private var handler: Handler?
    private let path: String
    /// Receives the changed paths of the batch (already filtered when a `filter` is set),
    /// so a consumer can refresh only what actually moved instead of everything it watches.
    private let onChange: ([String]) -> Void
    /// When set, only fire onChange if at least one changed path passes the filter.
    /// Runs off the main thread: it must only read values it captured.
    private let filter: ((String) -> Bool)?
    /// When set, the stream also watches the root itself (`WatchRoot`) and calls this when
    /// the watched path is deleted, renamed or moved — FSEvents reports that only on request.
    private let onRootChanged: (() -> Void)?

    init(
        path: String, filter: ((String) -> Bool)? = nil, onRootChanged: (() -> Void)? = nil,
        onChange: @escaping ([String]) -> Void
    ) {
        self.path = path
        self.filter = filter
        self.onRootChanged = onRootChanged
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let pathsToWatch = [path] as CFArray

        let handler = Handler(filter: filter, onChange: onChange, onRootChanged: onRootChanged)
        var context = FSEventStreamContext()
        // Retained here, released in stop() once the stream can no longer call back.
        context.info = Unmanaged.passRetained(handler).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let raw = unsafeBitCast(eventPaths, to: NSArray.self)
            var changed: [String] = []
            var rootChanged = false
            changed.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                if eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    rootChanged = true
                    continue
                }
                guard let p = raw[i] as? String else { continue }
                if let filter = handler.filter, !filter(p) { continue }
                changed.append(p)
            }
            if rootChanged, handler.onRootChanged != nil {
                DispatchQueue.main.async { if handler.active { handler.onRootChanged?() } }
            }
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async { if handler.active { handler.onChange(changed) } }
        }

        var flags =
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        if onRootChanged != nil { flags |= kFSEventStreamCreateFlagWatchRoot }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // latency in seconds
            UInt32(flags)
        )

        if let stream = stream {
            self.handler = handler
            FSEventStreamSetDispatchQueue(stream, Self.queue)
            FSEventStreamStart(stream)
        } else {
            Unmanaged.passUnretained(handler).release()
        }
    }

    func stop() {
        guard let stream = stream else { return }
        self.stream = nil
        let handler = self.handler
        self.handler = nil
        handler?.active = false
        // On the stream's queue: no callback runs while it is torn down, so
        // releasing the handler afterwards cannot free it mid-callback.
        Self.queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let handler { Unmanaged.passUnretained(handler).release() }
    }

    deinit {
        stop()
    }
}
