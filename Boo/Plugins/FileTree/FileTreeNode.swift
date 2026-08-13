import Foundation

/// Data model for file tree entries.
final class FileTreeNode: Identifiable, ObservableObject {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool

    @Published var children: [FileTreeNode]?
    @Published var isExpanded: Bool = false

    /// Incremented on structural changes so the parent view re-flattens the tree.
    /// Only meaningful on the root node.
    @Published var treeRevision: Int = 0

    /// Weak back-pointer to the tree root so child nodes can bump `treeRevision`.
    weak var root: FileTreeNode?

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Load or reload children for a directory.
    func loadChildren() {
        guard isDirectory else { return }
        let url = URL(fileURLWithPath: path)
        let treeRoot = root ?? self
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )

            // Build each child path from this node's own path rather than taking the
            // enumerator's `u.path`: FileManager hands back *resolved* paths (a cwd of
            // `/var/folders/…` lists as `/private/var/folders/…`), which would leave a
            // child in a different path form from its parent. Anything that compares node
            // paths across levels then silently misses — `refresh(changedDirs:)` skips
            // descendants, and `restoreExpanded` fails to match saved keys.
            let entries: [(name: String, path: String, isDir: Bool)] = urls.compactMap { u in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = u.lastPathComponent
                return (name: name, path: (path as NSString).appendingPathComponent(name), isDir: isDir)
            }

            let sorted = entries.sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir { return lhs.isDir }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
            children = newChildren
            if !unchanged { treeRoot.treeRevision &+= 1 }
        } catch {
            let wasEmpty = children?.isEmpty ?? false
            children = []
            if !wasEmpty { treeRoot.treeRevision &+= 1 }
        }
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
