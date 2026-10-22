import AppKit

extension Notification.Name {
    static let portsChanged = Notification.Name("BooPortsChanged")
}

/// Remembers which (pid, port) pairs each workspace has shown, so only
/// servers that appear while watching notify. The first scan of a workspace
/// seeds silently — switching to a workspace with running servers is not news.
struct PortTracker {
    private struct Key: Hashable {
        let pid: pid_t
        let port: UInt16
    }

    private var seen: [UUID: Set<Key>] = [:]

    /// Servers in `servers` not present in the previous scan of `workspace`.
    mutating func update(workspace: UUID, servers: [PaneServer]) -> [PaneServer] {
        let keys = Set(servers.map { Key(pid: $0.pid, port: $0.port) })
        defer { seen[workspace] = keys }
        guard let previous = seen[workspace] else { return [] }
        return servers.filter { !previous.contains(Key(pid: $0.pid, port: $0.port)) }
    }

    mutating func forget(workspace: UUID) { seen[workspace] = nil }
}

/// Polls listening ports of the active workspace every 2 s while the status
/// bar segment is enabled. Scans run off the main thread.
@MainActor final class PortMonitor {
    static let shared = PortMonitor()

    private(set) var servers: [PaneServer] = []
    private(set) var workspaceID: UUID?
    private var tracker = PortTracker()
    private var timer: Timer?
    private var scanning = false
    private let interval: TimeInterval = 2

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { PortMonitor.shared.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Rescan now, e.g. after stopping a server.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { PortMonitor.shared.tick() }
    }

    private func tick() {
        guard AppSettings.shared.statusBarShowPorts,
            let workspace = WindowManager.shared.activeController?.activeWorkspace
        else {
            tracker = PortTracker()
            publish([], workspace: nil)
            return
        }
        // Nobody sees the bar while another app is frontmost; resume on the next tick.
        guard !scanning, NSApp.isActive else { return }
        scanning = true
        let shells = PaneServers.shells(in: workspace)
        let id = workspace.id
        DispatchQueue.global(qos: .utility).async {
            let found = PaneServers.scan(shells)
            Task { @MainActor in
                let monitor = PortMonitor.shared
                monitor.scanning = false
                monitor.publish(found, workspace: id)
            }
        }
    }

    private func publish(_ found: [PaneServer], workspace: UUID?) {
        // Servers started while a workspace was in the background aren't news on return.
        if let old = workspaceID, old != workspace { tracker.forget(workspace: old) }
        if let workspace {
            for server in tracker.update(workspace: workspace, servers: found) { notify(server) }
        }
        guard found != servers || workspace != workspaceID else { return }
        servers = found
        workspaceID = workspace
        NotificationCenter.default.post(name: .portsChanged, object: nil)
    }

    private func notify(_ server: PaneServer) {
        guard let tabID = server.tabID, let location = AgentInbox.locateInWindows(tabID) else { return }
        ActivityNotifier.shared.notifyPort(
            server.port, process: server.processName, workspaceName: location.workspace.displayName,
            workspaceID: location.workspace.id, paneID: location.pane.id, tabIndex: location.tabIndex)
    }

    // MARK: - Actions

    func jump(to server: PaneServer) {
        guard let tabID = server.tabID, let location = AgentInbox.locateInWindows(tabID) else { return }
        AgentInbox.focus(location)
    }

    /// SIGTERM, or SIGKILL after confirmation when `force`.
    func stop(_ server: PaneServer, force: Bool) {
        if force {
            let alert = NSAlert()
            alert.messageText = "Force kill \(server.processName) (pid \(server.pid))?"
            alert.informativeText = "It is listening on \(server.hostLabel). Unsaved state in the process is lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Force Kill")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // The pid may have been reused since the scan; only signal it while it still listens there.
        guard PaneServers.listeningTCPPorts(pid: server.pid).contains(server.port) else {
            refreshSoon()
            return
        }
        kill(server.pid, force ? SIGKILL : SIGTERM)
        refreshSoon()
    }

    /// "⇄ 3000 · 5173", or "⇄ 4 ports" past three.
    static func label(for servers: [PaneServer]) -> String {
        servers.count > 3 ? "⇄ \(servers.count) ports" : "⇄ " + servers.map { String($0.port) }.joined(separator: " · ")
    }
}
