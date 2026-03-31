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

            let entries: [(name: String, path: String, isDir: Bool)] = urls.compactMap { u in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return (name: u.lastPathComponent, path: u.path, isDir: isDir)
            }

            let sorted = entries.sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir { return lhs.isDir }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            let newChildren = sorted.map { entry -> FileTreeNode in
                if let existing = children?.first(where: { $0.path == entry.path && $0.isDirectory == entry.isDir }) {
                    return existing
                }
                let child = FileTreeNode(name: entry.name, path: entry.path, isDirectory: entry.isDir)
                child.root = treeRoot
                return child
            }

            children = newChildren
            treeRoot.treeRevision &+= 1
        } catch {
            children = []
            treeRoot.treeRevision &+= 1
        }
    }

    /// Collect all expanded directory paths in this subtree.
    func expandedPaths() -> Set<String> {
        var result = Set<String>()
        if isDirectory && isExpanded {
            result.insert(path)
            for child in children ?? [] {
                result.formUnion(child.expandedPaths())
            }
        }
        return result
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

    /// Recursively refresh this node and all expanded children.
    /// When called on the root, triggers `objectWillChange` so SwiftUI
    /// picks up deep child-list mutations that would otherwise be invisible.
    func refreshAll(isRoot: Bool = true) {
        guard isDirectory else { return }
        if children != nil {
            loadChildren()
        }
        // Refresh expanded subdirectories
        for child in children ?? [] {
            if child.isDirectory && child.isExpanded {
                child.refreshAll(isRoot: false)
            }
        }
        // Force SwiftUI to re-render the tree from the root.
        if isRoot {
            objectWillChange.send()
        }
    }

}
