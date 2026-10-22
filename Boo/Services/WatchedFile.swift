import Foundation

/// Calls `onChange` on the main queue whenever one file in a directory is
/// written, replaced or removed. Watches the parent directory, so atomic saves
/// (write to temp + rename) and a file that doesn't exist yet both work.
final class WatchedFile {
    let path: String
    private var watcher: FileSystemWatcher?
    private var signature: (Date?, Int?)

    init(path: String) {
        self.path = path
    }

    func start(onChange: @escaping () -> Void) {
        guard watcher == nil else { return }
        signature = Self.signature(of: path)
        let target = (path as NSString).standardizingPath
        let name = (path as NSString).lastPathComponent
        watcher = FileSystemWatcher(
            path: (path as NSString).deletingLastPathComponent,
            filter: { changed in
                // FSEvents may report the path through /private or resolved links.
                (changed as NSString).lastPathComponent == name || (changed as NSString).standardizingPath == target
            }
        ) { [weak self] _ in
            guard let self else { return }
            // Several events arrive per save; only a real change reloads.
            let now = Self.signature(of: self.path)
            guard now.0 != self.signature.0 || now.1 != self.signature.1 else { return }
            self.signature = now
            onChange()
        }
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Records the file as it is now, so a write of our own doesn't echo back.
    func noteOwnWrite() {
        signature = Self.signature(of: path)
    }

    private static func signature(of path: String) -> (Date?, Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date, (attrs?[.size] as? NSNumber)?.intValue)
    }
}
