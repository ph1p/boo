import Combine
import Foundation

/// File tree node backed by remote directory listing (SSH or Docker).
final class RemoteFileTreeNode: Identifiable, ObservableObject {
    let id: UUID
    private(set) var name: String
    private(set) var remotePath: String
    let isDirectory: Bool
    let session: RemoteSessionType

    /// Callback for nodes to request a listing without holding a bridge reference.
    var onRequestListing: ((String) -> Void)?

    @Published var children: [RemoteFileTreeNode]?
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadFailed: Bool = false

    /// Incremented on any structural change (expand/collapse/children loaded)
    /// so the parent view re-flattens the tree.  Only meaningful on the root.
    @Published var treeRevision: Int = 0

    /// Weak back-pointer to the tree root so child nodes can bump `treeRevision`.
    weak var root: RemoteFileTreeNode?

    /// Number of automatic retries remaining (SSH master may still be connecting).
    private var retriesLeft = 15
    private var retryTimer: Timer?

    init(name: String, remotePath: String, isDirectory: Bool, session: RemoteSessionType) {
        self.id = UUID()
        self.name = name
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.session = session
    }

    /// Reset retry state for a manual retry from the failure view.
    func resetForRetry() {
        retriesLeft = 15
        loadFailed = false
    }

    func loadChildren() {
        guard isDirectory else { return }
        guard !isLoading else {
            remoteLog("[RemoteFileTree] loadChildren skipped (already loading): path=\(remotePath)")
            return
        }

        remoteLog("[RemoteFileTree] loadChildren: path=\(remotePath) session=\(session)")
        isLoading = true
        loadFailed = false

        RemoteExplorer.listRemoteDirectory(session: session, path: remotePath) { [weak self] entries in
            let apply = { [weak self] in
                guard let self = self else { return }

                guard let entries = entries else {
                    remoteLog(
                        "[RemoteFileTree] listRemoteDirectory returned nil for path=\(self.remotePath) retriesLeft=\(self.retriesLeft)"
                    )
                    // Connection failed — use SSHControlManager state to decide retry strategy.
                    let shouldRetry: Bool
                    let retryInterval: TimeInterval

                    if self.session.isSSHBased {
                        let target = self.session.sshConnectionTarget
                        switch SSHControlManager.shared.connectionState(for: target) {
                        case .connecting:
                            shouldRetry = self.retriesLeft > 0
                            retryInterval = 1.0
                        case .failed:
                            shouldRetry = false
                            retryInterval = 0
                        case .ready:
                            shouldRetry = self.retriesLeft > 10
                            retryInterval = 1.0
                        case nil:
                            shouldRetry = self.retriesLeft > 5
                            retryInterval = 2.0
                        }
                    } else {
                        shouldRetry = self.retriesLeft > 10
                        retryInterval = 2.0
                    }

                    if shouldRetry {
                        self.retriesLeft -= 1
                        self.retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) {
                            [weak self] _ in
                            guard let self = self else { return }
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

                remoteLog(
                    "[RemoteFileTree] listRemoteDirectory returned \(entries.count) entries for path=\(self.remotePath)"
                )
                self.applyEntries(entries)
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    /// Apply a set of entries as children, preserving existing expanded nodes.
    func applyEntries(_ entries: [RemoteExplorer.RemoteEntry]) {
        retriesLeft = 0
        retryTimer?.invalidate()
        retryTimer = nil
        isLoading = false
        loadFailed = false
        let treeRoot = root ?? self
        let newChildren = entries.map { entry in
            if let existing = children?.first(where: { $0.name == entry.name && $0.isDirectory == entry.isDirectory }) {
                return existing
            }
            let childPath = (remotePath as NSString).appendingPathComponent(entry.name)
            let child = RemoteFileTreeNode(
                name: entry.name,
                remotePath: childPath,
                isDirectory: entry.isDirectory,
                session: session
            )
            child.root = treeRoot
            child.onRequestListing = onRequestListing
            return child
        }
        children = newChildren
        treeRoot.treeRevision &+= 1
    }

    /// Update the display path when "~" resolves to an absolute path or on cd.
    func updatePath(_ newPath: String) {
        let newName = (newPath as NSString).lastPathComponent
        remotePath = newPath
        name = newName.isEmpty ? "/" : newName
        retryTimer?.invalidate()
        retryTimer = nil
        isLoading = false
        retriesLeft = 15
        loadFailed = false
    }

    /// Collect all expanded directory paths in this subtree.
    func expandedPaths() -> Set<String> {
        var result = Set<String>()
        if isDirectory && isExpanded {
            result.insert(remotePath)
            for child in children ?? [] {
                result.formUnion(child.expandedPaths())
            }
        }
        return result
    }

    /// Restore expanded state from a set of previously expanded paths.
    func restoreExpanded(_ paths: Set<String>) {
        guard isDirectory else { return }
        let shouldExpand = paths.contains(remotePath)
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

    func refreshAll(isRoot: Bool = true) {
        guard isDirectory else { return }
        if children != nil {
            retriesLeft = 3
            loadChildren()
        }
        for child in children ?? [] {
            if child.isDirectory && child.isExpanded {
                child.refreshAll(isRoot: false)
            }
        }
        if isRoot {
            objectWillChange.send()
        }
    }
}
