import Foundation

/// Manages directory bookmarks, persisted in UserDefaults.
final class BookmarkService {
    static let shared = BookmarkService()

    struct Bookmark: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var path: String
        var icon: String  // SF Symbol name
        var namespace: String

        init(name: String, path: String, icon: String = "folder", namespace: String = "local") {
            self.id = UUID()
            self.name = name
            self.path = path
            self.icon = icon
            self.namespace = namespace
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            path = try c.decode(String.self, forKey: .path)
            icon = try c.decode(String.self, forKey: .icon)
            namespace = try c.decodeIfPresent(String.self, forKey: .namespace) ?? "local"
        }
    }

    private let storageKey = "ExtermBookmarks"

    private(set) var bookmarks: [Bookmark] = []

    private init() {
        load()
    }

    func add(name: String, path: String, namespace: String = "local") {
        // Don't add duplicates within the same namespace
        guard !bookmarks.contains(where: { $0.path == path && $0.namespace == namespace }) else { return }
        let bookmark = Bookmark(name: name, path: path, namespace: namespace)
        bookmarks.append(bookmark)
        save()
    }

    func addCurrentDirectory(_ path: String, namespace: String = "local") {
        let name = (path as NSString).lastPathComponent
        add(name: name, path: path, namespace: namespace)
    }

    func bookmarks(for namespace: String) -> [Bookmark] {
        bookmarks.filter { $0.namespace == namespace }
    }

    func remove(at index: Int) {
        guard index >= 0, index < bookmarks.count else { return }
        bookmarks.remove(at: index)
        save()
    }

    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to name: String) {
        if let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[idx].name = name
            save()
        }
    }

    func move(from: Int, to: Int) {
        guard from >= 0, from < bookmarks.count, to >= 0, to < bookmarks.count else { return }
        let item = bookmarks.remove(at: from)
        bookmarks.insert(item, at: to)
        save()
    }

    func contains(path: String, namespace: String = "local") -> Bool {
        bookmarks.contains { $0.path == path && $0.namespace == namespace }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bookmarks) {
            try? data.write(to: URL(fileURLWithPath: ExtermPaths.bookmarksFile))
        }
    }

    private func load() {
        // Try file first, then fall back to UserDefaults for migration
        let filePath = ExtermPaths.bookmarksFile
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
            let saved = try? JSONDecoder().decode([Bookmark].self, from: data)
        {
            bookmarks = saved
            return
        }
        // Migrate from UserDefaults
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        bookmarks = saved
    }
}
