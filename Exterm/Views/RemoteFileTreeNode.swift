import Foundation

/// File tree node backed by remote directory listing (SSH or Docker).
final class RemoteFileTreeNode: Identifiable, ObservableObject {
    let id: UUID
    let name: String
    let remotePath: String
    let isDirectory: Bool
    let session: RemoteSessionType

    @Published var children: [RemoteFileTreeNode]?
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false

    init(name: String, remotePath: String, isDirectory: Bool, session: RemoteSessionType) {
        self.id = UUID()
        self.name = name
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.session = session
    }

    func loadChildren() {
        guard isDirectory, !isLoading else { return }
        isLoading = true

        RemoteExplorer.listRemoteDirectory(session: session, path: remotePath) { [weak self] entries in
            guard let self = self else { return }
            self.isLoading = false

            let newChildren = entries.map { entry in
                if let existing = self.children?.first(where: { $0.name == entry.name && $0.isDirectory == entry.isDirectory }) {
                    return existing
                }
                let childPath = (self.remotePath as NSString).appendingPathComponent(entry.name)
                return RemoteFileTreeNode(
                    name: entry.name,
                    remotePath: childPath,
                    isDirectory: entry.isDirectory,
                    session: self.session
                )
            }
            self.children = newChildren
        }
    }

    func refreshAll() {
        guard isDirectory else { return }
        if children != nil {
            loadChildren()
        }
        children?.forEach { child in
            if child.isDirectory && child.isExpanded {
                child.refreshAll()
            }
        }
    }
}
