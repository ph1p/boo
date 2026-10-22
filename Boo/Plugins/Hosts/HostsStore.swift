import AppKit
import Combine

/// Hosts from `~/.ssh/config` (and its includes), with when each was last
/// connected (from command history) and which have an open session.
@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore(path: ("~/.ssh/config" as NSString).expandingTildeInPath)

    let path: String
    @Published private(set) var hosts: [SSHHost] = []
    /// Last connection per alias.
    @Published private(set) var recent: [String: Date] = [:]
    /// Tab IDs with an open ssh session, per alias.
    @Published private(set) var live: [String: [UUID]] = [:]

    private var watchers: [String: WatchedFile] = [:]
    private var subscription: AnyCancellable?
    private var started = false

    init(path: String) {
        self.path = path
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
        refreshLive()
        refreshRecent()
        subscription = CommandLog.shared.finished.sink { [weak self] command in
            guard let self, AppSettings.shared.historyEnabled,
                let destination = SSHCommandLine.destination(of: command.command),
                let alias = self.alias(forDestination: destination)
            else { return }
            self.recent[alias] = max(self.recent[alias] ?? .distantPast, command.startedAt)
        }
    }

    func reload() {
        let config = SSHConfigParser.parse(path: path)
        if config.hosts != hosts { hosts = config.hosts }
        watch(config.files)
    }

    /// Watches exactly `files`; included files come and go with edits.
    private func watch(_ files: [String]) {
        let wanted = Set(files)
        for (file, watcher) in watchers where !wanted.contains(file) {
            watcher.stop()
            watchers[file] = nil
        }
        for file in files where watchers[file] == nil {
            let watcher = WatchedFile(path: file)
            watcher.start { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            watchers[file] = watcher
        }
    }

    /// The alias a destination (`user@host`) refers to, matched by alias or HostName.
    func alias(forDestination destination: String) -> String? {
        let host = SSHCommandLine.host(of: destination)
        return hosts.first { $0.alias == host }?.alias ?? hosts.first { $0.hostName == host }?.alias
    }

    func refreshLive() {
        var found: [String: [UUID]] = [:]
        for controller in WindowManager.shared.controllers {
            for workspace in controller.appState.workspaces {
                for pane in workspace.panes.values {
                    for tab in pane.tabs {
                        guard case .ssh(let host, let alias)? = tab.remoteSession,
                            let name = self.alias(forDestination: alias ?? host)
                        else { continue }
                        found[name, default: []].append(tab.id)
                    }
                }
            }
        }
        if found != live { live = found }
    }

    func refreshRecent() {
        guard AppSettings.shared.historyEnabled else { return }
        Task { [weak self] in
            let entries = await HistoryStore.shared.search(HistoryFilter(text: "ssh"), limit: 500)
            guard let self else { return }
            var found: [String: Date] = [:]
            for entry in entries {
                guard let destination = SSHCommandLine.destination(of: entry.command),
                    let alias = self.alias(forDestination: destination)
                else { continue }
                found[alias] = max(found[alias] ?? .distantPast, entry.startedAt)
            }
            if found != self.recent { self.recent = found }
        }
    }

    // MARK: - Actions

    static func command(for host: SSHHost) -> String {
        "ssh \(shellEscape(host.alias))"
    }

    /// Opens a new tab (or a split right of the focused pane) connected to `host`.
    func connect(_ host: SSHHost, split: Bool) {
        guard let controller = WindowManager.shared.activeController,
            let workspace = controller.activeWorkspace
        else { return }
        let command = Self.command(for: host)
        if split {
            controller.splitPane(workspace.activePaneID, in: workspace, toward: .right, command: command)
        } else {
            controller.openCommandTab(command, cwd: NSHomeDirectory())
        }
    }

    /// Focuses the first open session to `host`; false when there is none.
    @discardableResult
    func jumpToSession(_ host: SSHHost) -> Bool {
        refreshLive()
        guard let tabID = live[host.alias]?.first, let location = AgentInbox.locateInWindows(tabID) else {
            return false
        }
        AgentInbox.focus(location)
        return true
    }

    func editInConfig(_ host: SSHHost) {
        WindowManager.shared.activeController?.openFileInEditor(path: host.file, line: host.line, column: 1)
    }
}
