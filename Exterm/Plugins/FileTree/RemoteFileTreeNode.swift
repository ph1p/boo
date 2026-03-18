import Foundation

/// File tree node backed by remote directory listing (SSH or Docker).
final class RemoteFileTreeNode: Identifiable, ObservableObject {
    let id: UUID
    private(set) var name: String
    private(set) var remotePath: String
    let isDirectory: Bool
    let session: RemoteSessionType

    /// Optional bridge reference for in-session cached listings (root nodes only).
    weak var bridge: TerminalBridge?

    @Published var children: [RemoteFileTreeNode]?
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadFailed: Bool = false

    /// Number of automatic retries remaining (SSH may still be authenticating).
    private var retriesLeft = 3
    private var retryTimer: Timer?

    init(name: String, remotePath: String, isDirectory: Bool, session: RemoteSessionType) {
        self.id = UUID()
        self.name = name
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.session = session
    }

    func loadChildren() {
        guard isDirectory, !isLoading else { return }

        // Check in-session cached listing first (avoids separate SSH connection)
        if let bridge = bridge, let cached = bridge.cachedRemoteListing,
           cached.path == remotePath {
            applyEntries(cached.entries)
            return
        }

        isLoading = true
        loadFailed = false

        RemoteExplorer.listRemoteDirectory(session: session, path: remotePath) { [weak self] entries in
            guard let self = self else { return }

            guard let entries = entries else {
                // Connection failed — retry automatically if SSH may still be authenticating.
                // Keep isLoading = true during retries so the UI shows a continuous spinner
                // instead of flashing between loader and empty state.
                if self.retriesLeft > 0 {
                    self.retriesLeft -= 1
                    self.retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        // Reset so loadChildren()'s guard passes, then immediately re-enter.
                        // This happens in a single runloop tick so the UI never sees isLoading = false.
                        self.isLoading = false
                        self.loadChildren()
                    }
                    return
                }
                self.isLoading = false
                self.loadFailed = true
                self.children = []
                return
            }

            self.applyEntries(entries)
        }
    }

    /// Apply a set of entries as children, preserving existing expanded nodes.
    func applyEntries(_ entries: [RemoteExplorer.RemoteEntry]) {
        retriesLeft = 0
        isLoading = false
        loadFailed = false
        let newChildren = entries.map { entry in
            if let existing = children?.first(where: { $0.name == entry.name && $0.isDirectory == entry.isDirectory }) {
                return existing
            }
            let childPath = (remotePath as NSString).appendingPathComponent(entry.name)
            return RemoteFileTreeNode(
                name: entry.name,
                remotePath: childPath,
                isDirectory: entry.isDirectory,
                session: session
            )
        }
        children = newChildren
    }

    /// Update the display path when "~" resolves to an absolute path.
    func updatePath(_ newPath: String) {
        let newName = (newPath as NSString).lastPathComponent
        remotePath = newPath
        name = newName.isEmpty ? "/" : newName
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
