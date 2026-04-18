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
        get { queue.sync { _processes } }
        set {
            queue.sync {
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

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sweepTimer: DispatchSourceTimer?
    var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    let queue = DispatchQueue(label: "com.boo.socket", qos: .utility)

    /// Cached ancestor lookups — cleared on each sweep cycle.
    /// Key: (childPID, ancestorPID), Value: isDescendant.
    private var ancestorCache: [UInt64: Bool] = [:]

    /// Socket path: ~/.boo/boo.sock
    let socketPath: String = {
        (BooPaths.configDir as NSString).appendingPathComponent("boo.sock")
    }()

    private static let maxClients = 128

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
        queue.sync {
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
    var hasActiveProcesses: Bool { queue.sync { !_processes.isEmpty } }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            unlink(socketPath)

            serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
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
                serverFD = -1
                return
            }

            chmod(socketPath, 0o600)

            guard listen(serverFD, 8) == 0 else {
                booLog(.error, .socket, "listen failed: \(errno)")
                close(serverFD)
                serverFD = -1
                return
            }

            booLog(.info, .socket, "Listening on \(socketPath)")

            let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClient() }
            source.setCancelHandler { [weak self] in
                if let fd = self?.serverFD, fd >= 0 {
                    close(fd)
                    self?.serverFD = -1
                }
            }
            source.resume()
            acceptSource = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.sweepDeadProcesses() }
            timer.resume()
            sweepTimer = timer
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            sweepTimer?.cancel()
            sweepTimer = nil
            for (fd, source) in clientSources {
                source.cancel()
                close(fd)
            }
            clientSources.removeAll()
            clientBuffers.removeAll()
            subscriptions.removeAll()
            externalSegments.removeAll()
            commandHandlers.removeAll()
            if serverFD >= 0 {
                close(serverFD)
                serverFD = -1
            }
            unlink(socketPath)
            _processes.removeAll()
            ancestorCache.removeAll()
        }
    }

    // MARK: - Client Handling

    private func acceptClient() {
        // Enforce client limit
        guard clientSources.count < Self.maxClients else { return }

        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Verify peer is same user
        guard peerHasSameUID(clientFD) else {
            close(clientFD)
            return
        }

        // Non-blocking so broadcast writes don't stall on slow clients
        configureClientSocket(clientFD)

        clientBuffers[clientFD] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(fd: clientFD) }
        source.setCancelHandler { [weak self] in
            close(clientFD)
            self?.clientBuffers.removeValue(forKey: clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
            self?.cleanupClient(fd: clientFD)
        }
        source.resume()
        clientSources[clientFD] = source
    }

    /// Verify the connecting process belongs to the same user.
    private func peerHasSameUID(_ fd: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        clientBuffers[fd]?.append(contentsOf: buf[0..<n])

        // Guard against oversized buffers
        if let buffer = clientBuffers[fd], buffer.count > 65536 {
            clientSources[fd]?.cancel()
            return
        }

        while let buffer = clientBuffers[fd],
            let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n"))
        {
            let lineData = buffer[buffer.startIndex..<newlineIdx]
            clientBuffers[fd] = Data(buffer[buffer.index(after: newlineIdx)...])
            processCommand(data: lineData, clientFD: fd)
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
            "send_text":
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
                "category": $0.category
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

    @discardableResult
    func sendJSON(fd: Int32, dict: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        data.append(UInt8(ascii: "\n"))
        let ok = writeAll(fd: fd, data: data)
        if !ok {
            queue.async { [weak self] in
                self?.clientSources[fd]?.cancel()
            }
        }
        return ok
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

    private func configureClientSocket(_ fd: Int32) {
        var flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0

            while offset < data.count {
                let remaining = data.count - offset
                let pointer = baseAddress.advanced(by: offset)
                let written = send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))

                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    return false
                }

                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    guard waitUntilWritable(fd: fd) else { return false }
                case EPIPE:
                    return false
                default:
                    return false
                }
            }

            return true
        }
    }

    private func waitUntilWritable(fd: Int32, timeoutMS: Int32 = 250) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)

        while true {
            let result = poll(&descriptor, 1, timeoutMS)
            if result > 0 {
                let invalidMask = Int16(POLLERR | POLLHUP | POLLNVAL)
                if descriptor.revents & invalidMask != 0 {
                    return false
                }
                return descriptor.revents & Int16(POLLOUT) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return false
            }
        }
    }
}
