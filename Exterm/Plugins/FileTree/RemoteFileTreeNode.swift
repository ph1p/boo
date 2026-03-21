import Combine
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

    /// Subscription to bridge events for receiving in-session directory listings.
    private var bridgeSub: AnyCancellable?
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
        guard !isLoading else { return }

        // Check in-session cached listing first (avoids separate SSH connection)
        if let bridge = bridge, let cached = bridge.cachedRemoteListing,
            cached.path == remotePath
        {
            applyEntries(cached.entries)
            return
        }

        // Subscribe to bridge events so we pick up EXTERM_LS listings
        // from the injected shell hook (fires on every cd / prompt)
        subscribeToBridge()

        isLoading = true
        loadFailed = false

        RemoteExplorer.listRemoteDirectory(session: session, path: remotePath) { [weak self] entries in
            let apply = { [weak self] in
                guard let self = self else { return }

                guard let entries = entries else {
                    // Connection failed — use SSHControlManager state to decide retry strategy.
                    let shouldRetry: Bool
                    let retryInterval: TimeInterval

                    if case .ssh = self.session {
                        let target = self.session.sshConnectionTarget
                        switch SSHControlManager.shared.connectionState(for: target) {
                        case .connecting:
                            // Master still starting — keep retrying at 1s
                            shouldRetry = self.retriesLeft > 0
                            retryInterval = 1.0
                        case .failed:
                            // Master failed — stop immediately, rely on bridge subscription
                            // for in-session EXTERM_LS listings
                            shouldRetry = false
                            retryInterval = 0
                        case .ready:
                            // Master is ready but listing failed — retry up to 5 times (network glitch)
                            shouldRetry = self.retriesLeft > 10
                            retryInterval = 1.0
                        case nil:
                            // Not tracked by SSHControlManager. The user's interactive
                            // SSH session may still be authenticating (creating the
                            // ControlMaster socket). Retry for a while to give it time.
                            shouldRetry = self.retriesLeft > 5
                            retryInterval = 2.0
                        }
                    } else {
                        // Docker — retry a few times (container shell may take a moment)
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
                    // If we have a bridge subscription, keep loading state — the in-session
                    // EXTERM_LS protocol may deliver a listing via the existing PTY connection.
                    // This covers password-authenticated SSH where out-of-band SSH fails.
                    if self.bridgeSub != nil {
                        // Stay in isLoading state; bridge subscription will call applyEntries
                        // if an EXTERM_LS listing arrives.
                        return
                    }
                    self.isLoading = false
                    self.loadFailed = true
                    self.children = []
                    return
                }

                self.applyEntries(entries)
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    /// Subscribe to bridge events so EXTERM_LS listings update the tree in real-time.
    private func subscribeToBridge() {
        guard bridgeSub == nil, let bridge = bridge else { return }
        bridgeSub = bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self = self else { return }
                if case .remoteDirectoryListed(let path, let entries) = event,
                    path == self.remotePath
                {
                    self.applyEntries(entries)
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

    func refreshAll() {
        guard isDirectory else { return }
        if children != nil {
            loadChildren()
        }
        for child in children ?? [] {
            if child.isDirectory && child.isExpanded {
                child.refreshAll()
            }
        }
    }
}
