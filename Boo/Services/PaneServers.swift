import Darwin
import Foundation

/// A TCP port some process started from a terminal pane is listening on —
/// typically a dev server (`pnpm dev`, `rails s`, `python -m http.server`).
struct PaneServer: Equatable, Sendable {
    let port: UInt16
    let pid: pid_t
    /// Executable name of the listening process ("node", "python3.12").
    let processName: String
    /// Where it runs: "<tab title> · <workspace>".
    let location: String

    /// "localhost:3000" — the label shown in the menu and suggestions.
    var hostLabel: String { "localhost:\(port)" }
    /// "node — dev · api" — what runs it and where.
    var detail: String { "\(processName) — \(location)" }
    var url: URL { URL(string: "http://\(hostLabel)")! }

    /// The tab whose shell started it; nil in tests.
    var tabID: UUID? = nil
    /// When the listening process started.
    var startedAt: Date? = nil
}

/// Finds listening TCP ports owned by the process trees of terminal panes,
/// across every window. Reads sockets straight from libproc — no `lsof`
/// spawn — so a scan of a few dozen processes stays well under a frame.
enum PaneServers {
    /// A shell to scan, with the label its servers are shown under.
    struct Shell: Sendable {
        let pid: pid_t
        let location: String
        var tabID: UUID? = nil
    }

    /// Bound on processes walked per shell, so a fork bomb or a huge build
    /// tree can't stall the scan.
    static let maxDescendants = 256

    /// Every terminal tab with a known shell, across all windows.
    @MainActor static func shells() -> [Shell] {
        WindowManager.shared.controllers.flatMap { $0.appState.workspaces.flatMap(shells(in:)) }
    }

    /// Terminal tabs with a known shell in one workspace.
    @MainActor static func shells(in workspace: Workspace) -> [Shell] {
        var result: [Shell] = []
        for pane in workspace.panes.values {
            for tab in pane.tabs where tab.contentType == .terminal && tab.shellPID > 0 {
                let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let location = title.isEmpty ? workspace.displayName : "\(title) · \(workspace.displayName)"
                result.append(Shell(pid: tab.shellPID, location: location, tabID: tab.id))
            }
        }
        return result
    }

    /// Listening servers under `shells`, sorted by port, one entry per port.
    static func scan(_ shells: [Shell]) -> [PaneServer] {
        var byPort: [UInt16: PaneServer] = [:]
        var visited = Set<pid_t>()
        for shell in shells {
            for pid in ProcessTree.descendants(of: shell.pid, limit: maxDescendants)
            where visited.insert(pid).inserted {
                let ports = listeningTCPPorts(pid: pid)
                guard !ports.isEmpty else { continue }
                let name = ProcessTree.displayName(pid: pid)
                for port in ports where byPort[port] == nil {
                    byPort[port] = PaneServer(
                        port: port, pid: pid, processName: name, location: shell.location,
                        tabID: shell.tabID, startedAt: startTime(pid: pid))
                }
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    static func startTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// TCP ports `pid` has a socket in LISTEN state on (IPv4 and IPv6 merged).
    static func listeningTCPPorts(pid: pid_t) -> [UInt16] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdSize)
        let written = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }

        var ports: [UInt16] = []
        for fd in fds.prefix(Int(written) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                info.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport holds the port in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }
}

/// Main-actor front for `PaneServers`: scans off the main thread and caches
/// the result briefly, so focusing the address bar repeatedly stays cheap.
@MainActor final class PaneServerMonitor {
    static let shared = PaneServerMonitor()

    private(set) var servers: [PaneServer] = []
    private var lastScan: Date?
    private var pending: [([PaneServer]) -> Void] = []
    /// Results younger than this are reused instead of rescanning.
    private let maxAge: TimeInterval = 2

    private init() {}

    /// Calls `completion` on the main actor with the current servers —
    /// immediately when the cache is fresh, otherwise after a background scan.
    func refresh(_ completion: @escaping ([PaneServer]) -> Void) {
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge {
            return completion(servers)
        }
        pending.append(completion)
        guard pending.count == 1 else { return }  // a scan is already running
        let shells = PaneServers.shells()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PaneServers.scan(shells)
            Task { @MainActor in
                let monitor = PaneServerMonitor.shared
                monitor.servers = found
                monitor.lastScan = Date()
                let callbacks = monitor.pending
                monitor.pending = []
                for callback in callbacks { callback(found) }
            }
        }
    }
}
