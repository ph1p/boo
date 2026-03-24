import CoreServices
import Foundation

/// Watches a directory for file system changes using FSEvents.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
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
            DispatchQueue.main.async {
                watcher.onChange()
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
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Balance the passRetained() from start().
            Unmanaged.passUnretained(self).release()
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        stop()
    }
}
