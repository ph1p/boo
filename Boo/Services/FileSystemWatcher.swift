import CoreServices
import Foundation

/// Watches a directory for file system changes using FSEvents.
final class FileSystemWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    /// When set, only fire onChange if at least one changed path passes the filter.
    private let filter: ((String) -> Bool)?

    init(path: String, filter: ((String) -> Bool)? = nil, onChange: @escaping () -> Void) {
        self.path = path
        self.filter = filter
        self.onChange = onChange
    }

    func start() {
        let pathsToWatch = [path] as CFArray

        var context = FSEventStreamContext()
        // Use passRetained so the callback pointer stays valid until stop().
        context.info = Unmanaged.passRetained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let filter = watcher.filter else {
                DispatchQueue.main.async { watcher.onChange() }
                return
            }
            // Extract changed paths and apply filter before dispatching.
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            var matched = false
            for i in 0..<numEvents {
                if let p = paths[i] as? String, filter(p) {
                    matched = true
                    break
                }
            }
            if matched {
                DispatchQueue.main.async { watcher.onChange() }
            }
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
        // Balance the passRetained() from start().
        Unmanaged.passUnretained(self).release()
    }

    deinit {
        stop()
    }
}
