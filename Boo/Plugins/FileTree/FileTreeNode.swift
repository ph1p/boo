import Foundation

/// Data model for file tree entries. Mutated on the main thread only; the async loader
/// lists off-main and hops back before touching state (hence `@unchecked Sendable`).
final class FileTreeNode: Identifiable, ObservableObject, @unchecked Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool

    @Published var children: [FileTreeNode]?
    @Published var isExpanded: Bool = false

    /// Incremented on structural changes so the parent view re-flattens the tree.
    /// Only meaningful on the root node.
    @Published var treeRevision: Int = 0

    /// Incremented only when a re-read finds the directory contents changed on disk
    /// (not on expand/collapse or a first load), so the filter index knows to rebuild.
    /// Only meaningful on the root node.
    @Published private(set) var contentRevision: Int = 0

    /// Weak back-pointer to the tree root so child nodes can bump `treeRevision`.
    weak var root: FileTreeNode?

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// True while an async listing for this directory is in flight.
    @Published private(set) var isLoading = false
    /// Bumped per async load so a slow listing can't overwrite a newer one.
    private var loadGeneration = 0

    /// Git decorations for the tree. Only meaningful on the root node.
    @Published var gitStatus: FileTreeGitStatus?

    struct Entry: Sendable {
        let name: String
        let path: String
        let isDir: Bool
    }

    /// Load or reload children for a directory.
    func loadChildren() {
        guard isDirectory else { return }
        apply(Self.listEntries(of: path))
    }

    /// Off-main variant for user-initiated expands — a slow volume or a huge directory
    /// must not hitch the sidebar. Falls back to the sync path's diffing on apply.
    func loadChildrenAsync() {
        guard isDirectory else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let dirPath = path
        // Only show a spinner when the listing is actually slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.loadGeneration == generation, self.children == nil else { return }
            self.isLoading = true
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = Self.listEntries(of: dirPath)
            await MainActor.run {
                guard let self, self.loadGeneration == generation else { return }
                self.isLoading = false
                self.apply(entries)
            }
        }
    }

    /// Sorted listing of a directory (folders first), or nil when unreadable.
    ///
    /// Each child path is built from `dirPath` rather than taken from the enumerator's
    /// `u.path`: FileManager hands back *resolved* paths (a cwd of `/var/folders/…` lists
    /// as `/private/var/folders/…`), which would leave a child in a different path form
    /// from its parent. Anything that compares node paths across levels then silently
    /// misses — `refresh(changedDirs:)` skips descendants, and `restoreExpanded` fails to
    /// match saved keys.
    static func listEntries(of dirPath: String) -> [Entry]? {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else { return nil }
        let entries = urls.map { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = u.lastPathComponent
            return Entry(name: name, path: (dirPath as NSString).appendingPathComponent(name), isDir: isDir)
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func apply(_ listing: [Entry]?) {
        let treeRoot = root ?? self
        guard let sorted = listing else {
            let wasEmpty = children?.isEmpty ?? false
            let wasLoaded = children != nil
            children = []
            if !wasEmpty {
                treeRoot.treeRevision &+= 1
                if wasLoaded { treeRoot.contentRevision &+= 1 }
            }
            return
        }

        // Index existing children by path so reuse is O(n) rather than O(n²) —
        // this runs for every expanded directory on every FS event, and a
        // node_modules-sized listing makes the linear scan bite.
        var existingByPath: [String: FileTreeNode] = [:]
        for child in children ?? [] { existingByPath[child.path] = child }

        var reusedAll = true
        let newChildren = sorted.map { entry -> FileTreeNode in
            if let existing = existingByPath[entry.path], existing.isDirectory == entry.isDir {
                return existing
            }
            reusedAll = false
            let child = FileTreeNode(name: entry.name, path: entry.path, isDirectory: entry.isDir)
            child.root = treeRoot
            return child
        }

        // Skip the revision bump when nothing changed. A watched directory that
        // churns (build output, node_modules) otherwise re-flattens the whole
        // tree on every FS event, which shows up as visible reload flicker.
        let unchanged = reusedAll && children?.count == newChildren.count
        let wasLoaded = children != nil
        children = newChildren
        if !unchanged {
            treeRoot.treeRevision &+= 1
            if wasLoaded { treeRoot.contentRevision &+= 1 }
        }
    }

    /// Collapse every folder below this node.
    func collapseAll() {
        func collapse(_ node: FileTreeNode) {
            for child in node.children ?? [] where child.isDirectory && child.isExpanded {
                child.isExpanded = false
                collapse(child)
            }
        }
        collapse(self)
        (root ?? self).treeRevision &+= 1
    }

    /// Expand every folder from this node down to `path` so it becomes visible.
    /// Returns false when `path` isn't under this node.
    @discardableResult
    func reveal(_ path: String) -> Bool {
        let prefix = self.path.hasSuffix("/") ? self.path : self.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        var node = self
        let components = path.dropFirst(prefix.count).split(separator: "/")
        for component in components.dropLast() {
            if node.children == nil { node.loadChildren() }
            guard let next = node.children?.first(where: { $0.name == component && $0.isDirectory })
            else { return false }
            if !next.isExpanded {
                next.isExpanded = true
                next.loadChildren()
            }
            node = next
        }
        (root ?? self).treeRevision &+= 1
        return true
    }

    /// Collect all expanded directory paths in this subtree.
    func expandedPaths() -> Set<String> {
        var result = Set<String>()
        collectExpandedPaths(into: &result)
        return result
    }

    /// One accumulator threaded through the recursion — a `Set` per node plus a
    /// `formUnion` at every level is a lot of allocation for a deep tree.
    private func collectExpandedPaths(into result: inout Set<String>) {
        guard isDirectory, isExpanded else { return }
        result.insert(path)
        for child in children ?? [] {
            child.collectExpandedPaths(into: &result)
        }
    }

    /// Restore expanded state from a set of previously expanded paths.
    func restoreExpanded(_ paths: Set<String>) {
        guard isDirectory else { return }
        let shouldExpand = paths.contains(path)
        if shouldExpand && !isExpanded {
            isExpanded = true
            loadChildren()
        } else if !shouldExpand && isExpanded {
            isExpanded = false
        }
        for child in children ?? [] {
            child.restoreExpanded(paths)
        }
    }

    /// Refresh only the directories that an FS-event batch actually touched.
    ///
    /// A full `refreshAll` re-reads every expanded directory in the tree; with a deep
    /// tree open that is a lot of `contentsOfDirectory` calls per event burst, when the
    /// events usually name one or two directories. A node is re-read when it *is* a
    /// changed directory; it is descended into when a changed directory lies below it.
    func refresh(changedDirs: Set<String>) {
        guard isDirectory else { return }
        let treeRoot = root ?? self
        let before = treeRoot.treeRevision
        refreshMatching(changedDirs)
        if treeRoot.treeRevision != before {
            objectWillChange.send()
        }
    }

    private func refreshMatching(_ changedDirs: Set<String>) {
        // Anything below this node lives under "path/" — no descendant can be affected
        // unless a changed directory is this one or sits inside it.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let touchesSubtree = changedDirs.contains { $0 == path || $0.hasPrefix(prefix) }
        guard touchesSubtree else { return }
        if children != nil, changedDirs.contains(path) {
            loadChildren()
        }
        for child in children ?? [] where child.isDirectory && child.isExpanded {
            child.refreshMatching(changedDirs)
        }
    }

    /// Recursively refresh this node and all expanded children.
    /// When called on the root, triggers `objectWillChange` so SwiftUI
    /// picks up deep child-list mutations that would otherwise be invisible.
    func refreshAll(isRoot: Bool = true) {
        guard isDirectory else { return }
        let treeRoot = root ?? self
        let before = treeRoot.treeRevision
        if children != nil {
            loadChildren()
        }
        // Refresh expanded subdirectories
        for child in children ?? [] {
            if child.isDirectory && child.isExpanded {
                child.refreshAll(isRoot: false)
            }
        }
        // Force SwiftUI to re-render the tree from the root — but only when a child
        // list actually changed, so FS-event storms don't repaint the whole tree.
        if isRoot && treeRoot.treeRevision != before {
            objectWillChange.send()
        }
    }

}
