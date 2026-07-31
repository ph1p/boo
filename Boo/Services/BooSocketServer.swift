import Darwin
import Foundation

/// Generic Unix socket server for IPC between terminal child processes and Boo.
/// External tools (AI agents, build systems, test runners, etc.) connect and send
/// newline-delimited JSON commands. Plugins register handlers for command namespaces.
///
/// Thread safety: all socket I/O and `processes` mutations happen on `queue`.
/// Public read accessors snapshot state synchronously via `queue.sync`.
/// The `onStatusChanged` callback is always dispatched to the main thread.
///
/// Protocol:
///   → {"cmd":"<namespace>.<action>","pid":12345,...}\n
///   ← {"ok":true,...}\n
///
/// Built-in commands:
///   set_status    — register a process with metadata (pid, name, category)
///   clear_status  — unregister a process
///   list_status   — list all registered processes
///   get_context   — current terminal context snapshot
///   get_theme     — current theme info
///   get_settings  — current app settings
///   list_themes   — all available theme names
///   get_workspaces — list of workspaces
///   set_theme     — change the active theme
///   toggle_sidebar — toggle sidebar visibility
///   switch_workspace — activate a workspace by index
///   new_tab       — open a new tab (optionally at a path)
///   send_text     — write raw text to the active terminal
///   subscribe     — subscribe to push events
///   unsubscribe   — remove event subscriptions
///   statusbar.set   — push an external status bar segment
///   statusbar.clear — remove an external segment
///   statusbar.list  — list external segments
///
/// The socket path is exposed to child processes via `BOO_SOCK`.
final class BooSocketServer: @unchecked Sendable {
    static let shared = BooSocketServer()

    // MARK: - Process Status Tracking

    struct ProcessStatus: Equatable {
        let pid: pid_t
        let name: String
        let category: String  // "ai", "build", "test", "server", etc.
        let registeredAt: Date
        let metadata: [String: String]
    }

    /// Thread-safe process storage. Only mutated on `queue`.
    private var _processes: [pid_t: ProcessStatus] = [:]

    /// Thread-safe accessor. Setter is internal for testing via `@testable import`.
    var processes: [pid_t: ProcessStatus] {
        get { syncOnQueue { _processes } }
        set {
            syncOnQueue {
                _processes = newValue
                ancestorCache.removeAll()
            }
        }
    }

    /// Called on main thread when the process set changes.
    var onStatusChanged: (() -> Void)?

    /// Plugin command handlers. Key is the namespace prefix (e.g. "git", "docker").
    /// Handler receives the full JSON dict and returns a response dict.
    private var commandHandlers: [String: @Sendable ([String: Any]) -> [String: Any]?] = [:]

    private var sweepTimer: DispatchSourceTimer?
    let queue = DispatchQueue(label: "com.boo.socket", qos: .utility)

    /// Owns the sockets, client tables, accept limit and budgeted writes; this
    /// class supplies only the framing and the peer-UID check via `Delegate`.
    private lazy var core = SocketServerCore(
        queue: queue,
        config: SocketServerCore.Config(
            maxClients: 128,
            maxBufferBytes: 65536,
            // No idle deadline: subscriber clients legitimately sit silent between
            // events for the lifetime of the app.
            idleTimeout: nil,
            writeTimeout: 5,
            readChunk: 4096,
            logLabel: "Socket"
        ),
        delegate: self
    )

    /// Key used to detect re-entrant calls already executing on `queue`.
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// Run `body` on `queue` synchronously, or inline if already on `queue`.
    /// Prevents deadlock when `stop()` (or the `processes` setter) is invoked
    /// from a timer/event-handler that is itself executing on `queue`.
    private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: BooSocketServer.queueKey) == true {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    /// Cached ancestor lookups — cleared on each sweep cycle.
    /// Key: (childPID, ancestorPID), Value: isDescendant.
    private var ancestorCache: [UInt64: Bool] = [:]

    private init() {
        queue.setSpecific(key: BooSocketServer.queueKey, value: true)
    }

    /// Socket path: ~/.boo/boo.sock
    let socketPath: String = {
        (BooPaths.configDir as NSString).appendingPathComponent("boo.sock")
    }()

    // MARK: - Event Subscriptions

    /// Clients subscribed to push events. Key: client FD, Value: set of event names.
    /// Mutated only on `queue`.
    var subscriptions: [Int32: Set<String>] = [:]

    // MARK: - External Status Bar Segments

    /// External status bar segment info pushed by connected clients.
    struct ExternalSegmentInfo {
        let id: String
        let text: String
        let icon: String?
        let tint: String?
        let position: StatusBarPosition
        let priority: Int
        let ownerFD: Int32
    }

    /// External segments keyed by segment ID. Mutated only on `queue`.
    var externalSegments: [String: ExternalSegmentInfo] = [:]

    /// Called on main thread when external segments change.
    var onExternalSegmentsChanged: (([ExternalSegmentInfo]) -> Void)?

    /// Callback for control commands that need MainActor access.
    /// Set by MainWindowController on init.
    var onControlCommand: ((_ cmd: String, _ json: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void)?

    // MARK: - Plugin Command Registration

    /// Register a handler for a command namespace. Commands matching "namespace.action"
    /// or just "namespace" will be routed to this handler.
    func registerHandler(namespace: String, handler: @escaping @Sendable ([String: Any]) -> [String: Any]?) {
        queue.async { [self] in
            commandHandlers[namespace] = handler
        }
    }

    func unregisterHandler(namespace: String) {
        queue.async { [self] in
            commandHandlers.removeValue(forKey: namespace)
        }
    }

    // MARK: - Process Queries

    /// Returns the status of a registered process that is a descendant of `shellPID`.
    /// Thread-safe — synchronizes on `queue`.
    func activeProcess(shellPID: pid_t, category: String? = nil) -> ProcessStatus? {
        syncOnQueue {
            for (pid, status) in _processes {
                if let cat = category, status.category != cat { continue }
                if isDescendantCached(pid, of: shellPID) {
                    return status
                }
            }
            return nil
        }
    }

    /// Check if any process is registered (fast, thread-safe).
    var hasActiveProcesses: Bool { syncOnQueue { !_processes.isEmpty } }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            unlink(socketPath)

            let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFD >= 0 else {
                booLog(.error, .socket, "Failed to create socket: \(errno)")
                return
            }

            // Set non-blocking to avoid hangs on accept
            var flags = fcntl(serverFD, F_GETFL)
            flags |= O_NONBLOCK
            _ = fcntl(serverFD, F_SETFL, flags)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    _ = sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                        strlcpy(dest, ptr, 104)
                    }
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                booLog(.error, .socket, "bind failed: \(errno)")
                close(serverFD)
                return
            }

            chmod(socketPath, 0o600)

            guard listen(serverFD, 8) == 0 else {
                booLog(.error, .socket, "listen failed: \(errno)")
                close(serverFD)
                return
            }

            booLog(.info, .socket, "Listening on \(socketPath)")

            core.adoptListener(fd: serverFD)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.sweepDeadProcesses() }
            timer.resume()
            sweepTimer = timer
        }
    }

    func stop() {
        syncOnQueue {
            sweepTimer?.cancel()
            sweepTimer = nil
            core.shutdown()
            subscriptions.removeAll()
            externalSegments.removeAll()
            commandHandlers.removeAll()
            unlink(socketPath)
            _processes.removeAll()
            ancestorCache.removeAll()
        }
    }

    /// Clean up subscriptions and external segments owned by a disconnecting client.
    private func cleanupClient(fd: Int32) {
        subscriptions.removeValue(forKey: fd)
        let owned = externalSegments.filter { $0.value.ownerFD == fd }
        if !owned.isEmpty {
            for key in owned.keys {
                externalSegments.removeValue(forKey: key)
            }
            notifyExternalSegmentsChanged()
        }
    }

    // MARK: - Command Dispatch

    private func processCommand(data: Data, clientFD: Int32) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cmd = json["cmd"] as? String
        else {
            sendResponse(fd: clientFD, ok: false, error: "invalid json")
            return
        }

        // Built-in commands
        switch cmd {
        case "set_status":
            handleSetStatus(json: json, clientFD: clientFD)
            return
        case "clear_status":
            handleClearStatus(json: json, clientFD: clientFD)
            return
        case "list_status":
            handleListStatus(clientFD: clientFD)
            return

        // Query commands
        case "get_context":
            handleGetContext(clientFD: clientFD)
            return
        case "get_theme":
            handleGetTheme(clientFD: clientFD)
            return
        case "get_settings":
            handleGetSettings(clientFD: clientFD)
            return
        case "list_themes":
            handleListThemes(clientFD: clientFD)
            return
        case "get_workspaces":
            handleControlCommand(cmd: cmd, json: json, clientFD: clientFD)
            return

        // Control commands
        case "set_theme", "toggle_sidebar", "switch_workspace", "new_tab", "new_workspace",
            "send_text", "agent_idle", "get_state", "get_screen", "send_key", "select_pane",
            "select_tab":
            handleControlCommand(cmd: cmd, json: json, clientFD: clientFD)
            return

        // Subscriptions
        case "subscribe":
            handleSubscribe(json: json, clientFD: clientFD)
            return
        case "unsubscribe":
            handleUnsubscribe(json: json, clientFD: clientFD)
            return

        default:
            break
        }

        // Status bar namespace
        if cmd.hasPrefix("statusbar.") {
            handleStatusBarCommand(cmd: cmd, json: json, clientFD: clientFD)
            return
        }

        // Plugin namespace routing: "namespace.action" or "namespace"
        let namespace = cmd.split(separator: ".", maxSplits: 1).first.map(String.init) ?? cmd
        if let handler = commandHandlers[namespace] {
            if let response = handler(json) {
                sendJSON(fd: clientFD, dict: response)
            }
            return
        }

        sendResponse(fd: clientFD, ok: false, error: "unknown command: \(cmd)")
    }

    // MARK: - Built-in: Status

    private func handleSetStatus(json: [String: Any], clientFD: Int32) {
        guard let pid = json["pid"] as? Int,
            let name = json["name"] as? String, !name.isEmpty
        else {
            sendResponse(fd: clientFD, ok: false, error: "missing pid or name")
            return
        }
        let category = json["category"] as? String ?? "unknown"
        let p = pid_t(pid)

        guard kill(p, 0) == 0 || errno == EPERM else {
            sendResponse(fd: clientFD, ok: false, error: "process \(pid) not found")
            return
        }

        var meta: [String: String] = [:]
        if let m = json["metadata"] as? [String: String] {
            meta = m
        }

        let status = ProcessStatus(
            pid: p, name: name, category: category,
            registeredAt: Date(), metadata: meta
        )
        _processes[p] = status
        ancestorCache.removeAll()
        booLog(.debug, .socket, "Status set: pid=\(pid) name=\(name) category=\(category)")
        sendResponse(fd: clientFD, ok: true)
        notifyChanged()
    }

    private func handleClearStatus(json: [String: Any], clientFD: Int32) {
        guard let pid = json["pid"] as? Int else {
            sendResponse(fd: clientFD, ok: false, error: "missing pid")
            return
        }
        let p = pid_t(pid)
        if _processes.removeValue(forKey: p) != nil {
            ancestorCache.removeAll()
            booLog(.debug, .socket, "Status cleared: pid=\(pid)")
            notifyChanged()
        }
        sendResponse(fd: clientFD, ok: true)
    }

    private func handleListStatus(clientFD: Int32) {
        let list = _processes.values.map {
            [
                "pid": Int($0.pid),
                "name": $0.name,
                "category": $0.category,
                "metadata": $0.metadata
            ] as [String: Any]
        }
        sendJSON(fd: clientFD, dict: ["ok": true, "processes": list])
    }

    // MARK: - Response Helpers

    func sendResponse(fd: Int32, ok: Bool, error: String? = nil) {
        var resp: [String: Any] = ["ok": ok]
        if let e = error { resp["error"] = e }
        sendJSON(fd: fd, dict: resp)
    }

    /// Returns false if the client is gone — the core has already dropped it.
    @discardableResult
    func sendJSON(fd: Int32, dict: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        data.append(UInt8(ascii: "\n"))
        return core.write(fd: fd, data)
    }

    /// Close a client connection.
    func dropClient(fd: Int32) {
        core.drop(fd: fd)
    }

    /// Whether `fd` is still one of ours. Deferred replies must check this before
    /// writing: the descriptor may have been closed and reused for another client.
    /// Must be called on `queue`.
    func isConnected(fd: Int32) -> Bool {
        core.connectedFDs.contains(fd)
    }

    // MARK: - Sweep

    private func sweepDeadProcesses() {
        var removed = false
        for (pid, status) in _processes {
            errno = 0
            if kill(pid, 0) == -1, errno == ESRCH {
                booLog(.debug, .socket, "Dead process: pid=\(pid) name=\(status.name)")
                _processes.removeValue(forKey: pid)
                removed = true
            }
        }
        if removed {
            ancestorCache.removeAll()
            notifyChanged()
        }
    }

    private func notifyChanged() {
        let callback = onStatusChanged
        DispatchQueue.main.async { callback?() }
    }

    func notifyExternalSegmentsChanged() {
        let segments = Array(externalSegments.values)
        let callback = onExternalSegmentsChanged
        DispatchQueue.main.async { callback?(segments) }
    }

    // MARK: - Process Tree (with cache)

    /// Cached ancestor check — avoids repeated sysctl calls within a sweep/query cycle.
    private func isDescendantCached(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        let key = UInt64(UInt32(bitPattern: pid)) << 32 | UInt64(UInt32(bitPattern: ancestor))
        if let cached = ancestorCache[key] { return cached }
        let result = isDescendant(pid, of: ancestor)
        ancestorCache[key] = result
        return result
    }

    private func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            let parent = parentPID(of: current)
            if parent == current || parent <= 0 { return false }
            current = parent
        }
        return false
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - Framing

extension BooSocketServer: SocketServerCore.Delegate {

    /// Only same-user processes may drive the terminal.
    func socketServerShouldAccept(fd: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Newline-delimited JSON: consume one line per call. Bad JSON gets an error
    /// reply rather than a disconnect — a client may recover on the next line.
    func socketServerConsume(buffer: Data, fd: Int32) -> Int? {
        guard let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let line = buffer[buffer.startIndex..<newlineIdx]
        processCommand(data: line, clientFD: fd)
        return buffer.distance(from: buffer.startIndex, to: newlineIdx) + 1
    }

    func socketServerDidCloseClient(fd: Int32) {
        cleanupClient(fd: fd)
    }
}
