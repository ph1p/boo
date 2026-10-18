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

    /// Main-actor completion for the async loaders; always invoked on a later turn.
    typealias Completion = @MainActor @Sendable () -> Void

    /// Synchronous load. Only for a brand-new root's first paint and tests — anything
    /// driven by the UI or FS events goes through `loadAsync`.
    func loadChildren() {
        guard isDirectory else { return }
        apply(Self.listEntries(of: path))
    }

    /// Off-main variant for user-initiated expands — a slow volume or a huge directory
    /// must not hitch the sidebar. Falls back to the sync path's diffing on apply.
    func loadChildrenAsync(completion: Completion? = nil) {
        Self.loadAsync([self], completion: completion)
    }

    /// List every directory in `nodes` in one off-main hop, then apply all listings on
    /// main together. Existing children stay in place until their listing lands, so a
    /// reload never blanks a folder. Each node's generation is bumped so an older
    /// in-flight load can't overwrite a newer one.
    static func loadAsync(_ nodes: [FileTreeNode], completion: Completion? = nil) {
        let dirs = nodes.filter(\.isDirectory)
        guard !dirs.isEmpty else {
            if let completion { Task { @MainActor in completion() } }
            return
        }
        var generations: [Int] = []
        for node in dirs {
            node.loadGeneration &+= 1
            let generation = node.loadGeneration
            generations.append(generation)
            // Only show a spinner when the listing is actually slow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak node] in
                guard let node, node.loadGeneration == generation, node.children == nil else { return }
                node.isLoading = true
            }
        }
        let paths = dirs.map(\.path)
        let expected = generations
        Task.detached(priority: .userInitiated) {
            let listings = paths.map { Self.listEntries(of: $0) }
            await MainActor.run {
                for (index, node) in dirs.enumerated() where node.loadGeneration == expected[index] {
                    node.isLoading = false
                    node.apply(listings[index])
                }
                completion?()
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
        if !unchanged {
            // `children` is @Published: reassigning an identical listing would
            // still re-render every view observing this node (the whole tree at the root).
            children = newChildren
            treeRoot.treeRevision &+= 1
            if wasLoaded { treeRoot.contentRevision &+= 1 }
        }
    }

    /// Expand this folder and reload it plus every still-expanded descendant — their
    /// listings went stale while hidden. Current children stay on screen until the new
    /// listings land.
    func expand() {
        guard isDirectory else { return }
        isExpanded = true
        (root ?? self).treeRevision &+= 1
        var stale = [self]
        collectExpandedDescendants(into: &stale)
        Self.loadAsync(stale)
    }

    /// Collapse this folder and drop the listings it now hides.
    func collapse() {
        guard isDirectory, isExpanded else { return }
        isExpanded = false
        releaseHiddenDescendants()
        (root ?? self).treeRevision &+= 1
    }

    private func collectExpandedDescendants(into result: inout [FileTreeNode]) {
        for child in children ?? [] where child.isDirectory && child.isExpanded {
            result.append(child)
            child.collectExpandedDescendants(into: &result)
        }
    }

    /// Above this many retained nodes, a hidden subtree is dropped wholesale instead
    /// of kept around for its nested open folders.
    static let hiddenRetainLimit = 2000

    /// Release listings nobody can see below this (collapsed) node: every collapsed
    /// descendant loses its children, which are re-listed on expand anyway. This node
    /// keeps its own listing so re-expanding it paints immediately, and expanded
    /// descendants keep theirs so their open state survives a collapse/expand of the
    /// parent — unless that adds up to more than `hiddenRetainLimit` nodes, in which
    /// case the whole subtree collapses (its nested state isn't persisted either: see
    /// `expandedPaths`).
    private func releaseHiddenDescendants() {
        var retained = 0
        func prune(_ node: FileTreeNode) {
            for child in node.children ?? [] where child.isDirectory {
                if child.isExpanded {
                    retained += child.children?.count ?? 0
                    prune(child)
                } else if child.children != nil {
                    child.children = nil
                }
            }
        }
        prune(self)
        guard retained > Self.hiddenRetainLimit else { return }
        for child in children ?? [] where child.isDirectory {
            child.isExpanded = false
            child.children = nil
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
        releaseHiddenDescendants()
        (root ?? self).treeRevision &+= 1
    }

    /// Expand every folder from this node down to `path` so it becomes visible,
    /// loading unread folders off-main one level per hop. Returns false when `path`
    /// isn't under this node; `completion` reports whether every folder was found.
    @discardableResult
    func reveal(_ path: String, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) -> Bool {
        let prefix = self.path.hasSuffix("/") ? self.path : self.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let components = path.dropFirst(prefix.count).split(separator: "/").dropLast()
        revealStep(components.map(String.init)[...], completion: completion)
        return true
    }

    private func revealStep(
        _ components: ArraySlice<String>, completion: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        let treeRoot = root ?? self
        func finish(_ found: Bool) {
            treeRoot.treeRevision &+= 1
            if let completion { Task { @MainActor in completion(found) } }
        }
        guard let component = components.first else { return finish(true) }
        guard let children else {
            Self.loadAsync([self]) { [self] in
                // Still unlisted means a newer load superseded this one; stop here
                // rather than chase it.
                guard self.children != nil else { return finish(false) }
                self.revealStep(components, completion: completion)
            }
            return
        }
        guard let next = children.first(where: { $0.name == component && $0.isDirectory })
        else { return finish(false) }
        let rest = components.dropFirst()
        if next.isExpanded, next.children != nil {
            next.revealStep(rest, completion: completion)
        } else {
            next.isExpanded = true
            treeRoot.treeRevision &+= 1
            Self.loadAsync([next]) { next.revealStep(rest, completion: completion) }
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

    /// Restore expanded state from a set of previously expanded paths. Flags on
    /// already-listed nodes flip immediately; folders that open are listed off-main in
    /// one batch per tree level, then their children are restored in turn.
    func restoreExpanded(_ paths: Set<String>, completion: Completion? = nil) {
        Self.restoreLevel([self], paths: paths, treeRoot: root ?? self, completion: completion)
    }

    private static func restoreLevel(
        _ nodes: [FileTreeNode], paths: Set<String>, treeRoot: FileTreeNode, completion: Completion?
    ) {
        var opened: [FileTreeNode] = []
        var changed = false
        func visit(_ node: FileTreeNode) {
            guard node.isDirectory else { return }
            let shouldExpand = paths.contains(node.path)
            if shouldExpand && (!node.isExpanded || node.children == nil) {
                if !node.isExpanded { changed = true }
                node.isExpanded = true
                opened.append(node)
                return
            }
            if !shouldExpand && node.isExpanded {
                node.isExpanded = false
                changed = true
            }
            for child in node.children ?? [] { visit(child) }
        }
        nodes.forEach(visit)
        if changed { treeRoot.treeRevision &+= 1 }
        guard !opened.isEmpty else {
            if let completion { Task { @MainActor in completion() } }
            return
        }
        let batch = opened
        loadAsync(batch) {
            restoreLevel(
                batch.flatMap { $0.children ?? [] }, paths: paths, treeRoot: treeRoot,
                completion: completion)
        }
    }

    /// Refresh only the directories that an FS-event batch actually touched.
    ///
    /// A full `refreshAll` re-reads every expanded directory in the tree; with a deep
    /// tree open that is a lot of `contentsOfDirectory` calls per event burst, when the
    /// events usually name one or two directories. A node is re-read when it *is* a
    /// changed directory; it is descended into when a changed directory lies below it.
    /// The re-reads run off-main in one batch.
    func refresh(changedDirs: Set<String>, completion: Completion? = nil) {
        var stale: [FileTreeNode] = []
        if isDirectory { collectMatching(changedDirs, into: &stale) }
        reload(stale, completion: completion)
    }

    private func collectMatching(_ changedDirs: Set<String>, into result: inout [FileTreeNode]) {
        // Anything below this node lives under "path/" — no descendant can be affected
        // unless a changed directory is this one or sits inside it.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let touchesSubtree = changedDirs.contains { $0 == path || $0.hasPrefix(prefix) }
        guard touchesSubtree else { return }
        if children != nil, changedDirs.contains(path) {
            result.append(self)
        }
        for child in children ?? [] where child.isDirectory && child.isExpanded {
            child.collectMatching(changedDirs, into: &result)
        }
    }

    /// Refresh this node and all expanded children, off-main in one batch.
    func refreshAll(completion: Completion? = nil) {
        var stale: [FileTreeNode] = []
        if isDirectory, children != nil { stale.append(self) }
        collectExpandedDescendants(into: &stale)
        reload(stale.filter { $0.children != nil }, completion: completion)
    }

    /// Re-list `nodes`, then trigger `objectWillChange` so SwiftUI picks up deep
    /// child-list mutations that would otherwise be invisible — but only when a child
    /// list actually changed, so FS-event storms don't repaint the whole tree.
    private func reload(_ nodes: [FileTreeNode], completion: Completion?) {
        let treeRoot = root ?? self
        let before = treeRoot.treeRevision
        Self.loadAsync(nodes) { [self] in
            if treeRoot.treeRevision != before { self.objectWillChange.send() }
            completion?()
        }
    }
}
