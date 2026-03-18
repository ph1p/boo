import Foundation

/// Data model for file tree entries.
final class FileTreeNode: Identifiable, ObservableObject {
    let id: UUID
    let name: String
    let path: String
    let isDirectory: Bool

    @Published var children: [FileTreeNode]?
    @Published var isExpanded: Bool = false

    init(name: String, path: String, isDirectory: Bool) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Load or reload children for a directory.
    func loadChildren() {
        guard isDirectory else { return }
        let url = URL(fileURLWithPath: path)
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
                if let existing = children?.first(where: { $0.name == entry.name && $0.isDirectory == entry.isDir }) {
                    return existing
                }
                return FileTreeNode(name: entry.name, path: entry.path, isDirectory: entry.isDir)
            }

            children = newChildren
        } catch {
            children = []
        }
    }

    /// Recursively refresh this node and all expanded children.
    func refreshAll() {
        guard isDirectory else { return }
        if children != nil {
            loadChildren()
        }
        // Refresh expanded subdirectories
        children?.forEach { child in
            if child.isDirectory && child.isExpanded {
                child.refreshAll()
            }
        }
    }

}
