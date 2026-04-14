import Foundation

/// A single browser history entry.
struct BrowserHistoryEntry: Codable, Identifiable {
    let id: UUID
    let title: String
    let url: URL
    let visitedAt: Date

    init(title: String, url: URL, visitedAt: Date = .now) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

/// Persists and vends browser history entries.
/// Thread-safe via main-actor isolation — all mutations happen on the main thread.
@MainActor
final class BrowserHistory {
    static let shared = BrowserHistory()

    private(set) var entries: [BrowserHistoryEntry] = []

    private var saveURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".boo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser_history.json")
    }

    private init() {
        load()
    }

    /// Record a page visit. Deduplicates consecutive identical URLs.
    func record(title: String, url: URL) {
        guard AppSettings.shared.browserHistoryEnabled else { return }
        // Skip internal/blank pages
        guard url.scheme == "http" || url.scheme == "https" else { return }
        // Deduplicate consecutive same URL
        if entries.first?.url == url { return }
        let entry = BrowserHistoryEntry(
            title: title.isEmpty ? url.host ?? url.absoluteString : title,
            url: url
        )
        entries.insert(entry, at: 0)
        // Cap at configured limit
        let limit = AppSettings.shared.browserHistoryLimit
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        save()
        NotificationCenter.default.post(name: .browserHistoryChanged, object: nil)
    }

    /// Remove all entries.
    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: saveURL)
        NotificationCenter.default.post(name: .browserHistoryChanged, object: nil)
    }

    /// Remove a single entry by id.
    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
        NotificationCenter.default.post(name: .browserHistoryChanged, object: nil)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
            let decoded = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }
}

extension Notification.Name {
    static let browserHistoryChanged = Notification.Name("browserHistoryChanged")
}
