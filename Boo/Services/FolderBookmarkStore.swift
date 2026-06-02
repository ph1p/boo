import Cocoa
import Foundation

/// Persists security-scoped bookmarks for user-selected folders so Boo can access
/// them across relaunches without prompting again.
///
/// Usage:
///   - After an NSOpenPanel picks a URL: `FolderBookmarkStore.shared.save(url)`
///   - At app launch: `FolderBookmarkStore.shared.restoreAll()`
///   - At app termination: `FolderBookmarkStore.shared.stopAll()`
@MainActor
final class FolderBookmarkStore {
    static let shared = FolderBookmarkStore()

    // path → active security-scoped URL (already started)
    private var activeAccess: [String: URL] = [:]

    private let storePath = BooPaths.bookmarksFile

    private init() {}

    // MARK: - Save

    /// Save only if this path has no bookmark yet. Used for paths that predate bookmark persistence.
    func saveIfNeeded(_ url: URL) {
        let all = load()
        guard all[url.path] == nil else { return }
        save(url)
    }

    /// Create and persist a security-scoped bookmark for `url`.
    /// Call immediately after the user selects a folder in NSOpenPanel.
    func save(_ url: URL) {
        guard
            let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        else {
            booLog(.warning, .app, "[Bookmarks] failed to create bookmark for \(url.path)")
            return
        }
        var all = load()
        all[url.path] = data
        persist(all)
        // Start access immediately so this session benefits too
        startAccessing(url: url, path: url.path)
    }

    // MARK: - Restore on launch

    /// Resolve all saved bookmarks and call startAccessingSecurityScopedResource on each.
    func restoreAll() {
        var all = load()
        var dirty = false
        for (path, data) in all {
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
            else {
                booLog(.warning, .app, "[Bookmarks] failed to resolve bookmark for \(path) — removing")
                all.removeValue(forKey: path)
                dirty = true
                continue
            }
            if isStale {
                // Refresh the bookmark data. The resolved url.path may differ from the
                // stored key (e.g. the folder moved), so drop the old key to avoid a
                // stale duplicate entry.
                if let fresh = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                {
                    if url.path != path { all.removeValue(forKey: path) }
                    all[url.path] = fresh
                    dirty = true
                }
            }
            startAccessing(url: url, path: url.path)
        }
        if dirty { persist(all) }
    }

    // MARK: - Stop on termination

    func stopAll() {
        for (_, url) in activeAccess {
            url.stopAccessingSecurityScopedResource()
        }
        activeAccess.removeAll()
    }

    // MARK: - Private

    private func startAccessing(url: URL, path: String) {
        if activeAccess[path] != nil { return }
        guard url.startAccessingSecurityScopedResource() else {
            booLog(.warning, .app, "[Bookmarks] startAccessingSecurityScopedResource failed for \(path)")
            return
        }
        activeAccess[path] = url
        booLog(.debug, .app, "[Bookmarks] restored access for \(path)")
    }

    private func load() -> [String: Data] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
            let dict = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return [:] }
        return dict
    }

    private func persist(_ dict: [String: Data]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }
}
