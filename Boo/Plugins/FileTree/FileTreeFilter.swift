import Foundation

/// One searchable entry below the tree root.
struct FileTreeIndexEntry: Equatable, Sendable {
    let name: String
    /// Path relative to the tree root, `/`-separated.
    let relativePath: String
    let isDirectory: Bool
}

/// A filter hit, ranked by `score`.
struct FileTreeFilterMatch: Equatable, Sendable {
    let entry: FileTreeIndexEntry
    let score: Int
    /// Matched character offsets into `entry.name` (empty when only the path matched).
    let nameHighlights: [Int]
}

enum FileTreeIndex {
    /// Folders never worth descending into when no git index is available.
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", "Pods", ".next",
        ".venv", "venv", "__pycache__", ".gradle", ".cache"
    ]

    /// Build the index for `rootPath`: tracked + untracked-not-ignored files from git
    /// when the root is inside a repo (exact, and fast on big trees), else a bounded walk.
    static func build(rootPath: String, showHidden: Bool, limit: Int = 50_000) -> [FileTreeIndexEntry] {
        if let files = gitFiles(rootPath: rootPath) {
            return entries(fromRelativeFiles: files, showHidden: showHidden, limit: limit)
        }
        return walk(rootPath: rootPath, showHidden: showHidden, limit: limit)
    }

    /// Turn a list of relative file paths into file + implied-folder entries.
    static func entries(
        fromRelativeFiles files: [String], showHidden: Bool, limit: Int
    ) -> [FileTreeIndexEntry] {
        var result: [FileTreeIndexEntry] = []
        var seenDirs = Set<String>()
        for file in files {
            if result.count >= limit { break }
            let components = file.split(separator: "/")
            if !showHidden && components.contains(where: { $0.hasPrefix(".") }) { continue }
            var dir = ""
            for component in components.dropLast() {
                dir = dir.isEmpty ? String(component) : dir + "/" + component
                if seenDirs.insert(dir).inserted {
                    result.append(FileTreeIndexEntry(name: String(component), relativePath: dir, isDirectory: true))
                }
            }
            if let last = components.last {
                result.append(FileTreeIndexEntry(name: String(last), relativePath: file, isDirectory: false))
            }
        }
        return result
    }

    private static func gitFiles(rootPath: String) -> [String]? {
        // ls-files paths are relative to -C, i.e. to the tree root — no path-form mapping.
        GitPlugin.gitOutput(["-C", rootPath, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])?
            .split(separator: "\0").map(String.init)
    }

    private static func walk(rootPath: String, showHidden: Bool, limit: Int) -> [FileTreeIndexEntry] {
        let rootURL = URL(fileURLWithPath: rootPath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: showHidden ? [] : [.skipsHiddenFiles])
        else { return [] }
        var result: [FileTreeIndexEntry] = []
        for case let url as URL in enumerator {
            if result.count >= limit { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            // The enumerator may yield resolved URLs (`/private/var/…`), so take the last
            // `level` components rather than string-slicing off the root path.
            let rel = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            guard !rel.isEmpty else { continue }
            result.append(FileTreeIndexEntry(name: url.lastPathComponent, relativePath: rel, isDirectory: isDir))
        }
        return result
    }
}

enum FileTreeFuzzy {
    /// Score `query` against an entry; nil when it doesn't match. A query containing
    /// `/` matches the relative path; otherwise the name is tried first and the path is
    /// a weaker fallback (so `ftv` still finds `FileTree/View.swift`).
    static func match(_ query: String, _ entry: FileTreeIndexEntry) -> FileTreeFilterMatch? {
        match(Array(query.lowercased()), entry)
    }

    /// `q` is the already-lowercased query, so `rank` lowercases it once, not per entry.
    static func match(_ q: [Character], _ entry: FileTreeIndexEntry) -> FileTreeFilterMatch? {
        guard !q.isEmpty else { return nil }
        if !q.contains("/"), let (score, hits) = score(q, entry.name) {
            // Shorter paths win ties: the shallow `README.md` before `docs/x/README.md`.
            let depthPenalty = entry.relativePath.filter { $0 == "/" }.count
            return FileTreeFilterMatch(entry: entry, score: score * 4 - depthPenalty, nameHighlights: hits)
        }
        if let (score, _) = score(q, entry.relativePath) {
            return FileTreeFilterMatch(entry: entry, score: score, nameHighlights: [])
        }
        return nil
    }

    /// Subsequence match with bonuses for a prefix hit, word-boundary hits and runs.
    static func score(_ q: [Character], _ candidate: String) -> (Int, [Int])? {
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        guard q.count <= c.count else { return nil }
        var hits: [Int] = []
        hits.reserveCapacity(q.count)
        var qi = 0
        var score = 0
        var lastHit = -2
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var bonus = 1
            if ci == 0 {
                bonus += 8
            } else {
                let prev = original[ci - 1]
                if "/._- ".contains(prev) || (prev.isLowercase && original[ci].isUppercase) { bonus += 5 }
            }
            if lastHit == ci - 1 { bonus += 4 }
            score += bonus
            hits.append(ci)
            lastHit = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if q.count == c.count { score += 10 }
        return (score, hits)
    }

    /// Rank every entry and keep the best `limit`.
    static func rank(_ query: String, in index: [FileTreeIndexEntry], limit: Int = 200) -> [FileTreeFilterMatch] {
        let q = Array(query.lowercased())
        var matches: [FileTreeFilterMatch] = []
        for entry in index {
            // Superseded by a newer keystroke — stop scanning.
            if Task.isCancelled { return [] }
            if let m = match(q, entry) { matches.append(m) }
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entry.relativePath.localizedStandardCompare($1.entry.relativePath) == .orderedAscending
        }
        return Array(matches.prefix(limit))
    }
}

/// Live filter state for one tree view. The index is built lazily on the first query
/// and rebuilt when the tree reports a change, all off the main thread.
@MainActor
final class FileTreeFilterModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var matches: [FileTreeFilterMatch] = []
    @Published private(set) var isIndexing = false

    var isActive: Bool { !trimmedQuery.isEmpty }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var rootPath = ""
    private var showHidden = false
    private var index: [FileTreeIndexEntry]?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    func configure(rootPath: String, showHidden: Bool) {
        guard rootPath != self.rootPath || showHidden != self.showHidden else { return }
        self.rootPath = rootPath
        self.showHidden = showHidden
        invalidate()
    }

    /// Drop the index; rebuilt immediately only while a query is showing.
    func invalidate() {
        index = nil
        indexTask?.cancel()
        indexTask = nil
        if isActive { scheduleSearch() }
    }

    func clear() { query = "" }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            matches = []
            return
        }
        guard let index else {
            buildIndex()
            return
        }
        // Detached (not a child of a main-actor task) so `cancel()` reaches the scan
        // inside `rank` and a superseded keystroke stops early.
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ranked = FileTreeFuzzy.rank(q, in: index)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.trimmedQuery == q else { return }
                self.matches = ranked
            }
        }
    }

    private func buildIndex() {
        guard indexTask == nil else { return }
        let root = rootPath
        let hidden = showHidden
        isIndexing = true
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                FileTreeIndex.build(rootPath: root, showHidden: hidden)
            }.value
            guard !Task.isCancelled, let self, self.rootPath == root else { return }
            self.index = built
            self.indexTask = nil
            self.isIndexing = false
            self.scheduleSearch()
        }
    }
}
