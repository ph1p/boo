import CoreServices
import Foundation

/// Watches a directory for file system changes using FSEvents.
final class FileSystemWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let path: String
    /// Receives the changed paths of the batch (already filtered when a `filter` is set),
    /// so a consumer can refresh only what actually moved instead of everything it watches.
    private let onChange: ([String]) -> Void
    /// When set, only fire onChange if at least one changed path passes the filter.
    private let filter: ((String) -> Bool)?

    init(path: String, filter: ((String) -> Bool)? = nil, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.filter = filter
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let pathsToWatch = [path] as CFArray

        var context = FSEventStreamContext()
        // Unretained: the stream runs on the main queue and stop()/deinit
        // invalidate it there before self can go away, so the pointer never
        // outlives the watcher. A retained reference would keep the watcher
        // (and its onChange closure graph) alive forever unless stop() was
        // called explicitly — deinit could never run.
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let raw = unsafeBitCast(eventPaths, to: NSArray.self)
            var changed: [String] = []
            changed.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                guard let p = raw[i] as? String else { continue }
                if let filter = watcher.filter, !filter(p) { continue }
                changed.append(p)
            }
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async { watcher.onChange(changed) }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // latency in seconds
            UInt32(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream = stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
