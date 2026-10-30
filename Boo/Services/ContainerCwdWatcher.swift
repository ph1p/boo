import Foundation

/// Single persistent watcher per container that tracks ALL interactive shells' CWDs.
///
/// Strategy:
/// 1. One hidden `docker exec sh` per container target (not per tab).
/// 2. On each tick, reads all PTY PIDs and their CWDs: every second while
///    the focused tab is one of its tabs, every 5 seconds otherwise.
/// 3. Maintains a PID→CWD map and detects changes.
/// 4. Tabs register/unregister and get assigned to specific PIDs.
/// 5. When a tab registers, it gets the newest unassigned PID.
/// 6. CWD changes for a tab's assigned PID are reported to that tab.
final class ContainerCwdWatcher: @unchecked Sendable {
    /// One watcher per container target.
    private nonisolated(unsafe) static var watchers: [String: ContainerCwdWatcher] = [:]
    private static let lock = NSLock()

    /// Get or create a watcher for a container target.
    static func shared(for session: RemoteSessionType) -> ContainerCwdWatcher? {
        guard case .container(let target, _) = session else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = watchers[target] { return existing }
        let watcher = ContainerCwdWatcher(session: session)
        watchers[target] = watcher
        watcher.start()
        return watcher
    }

    /// Remove a watcher when no tabs are using it.
    static func releaseIfUnused(for session: RemoteSessionType) {
        guard case .container(let target, _) = session else { return }
        lock.lock()
        defer { lock.unlock() }
        if let watcher = watchers[target], watcher.tabCallbacks.isEmpty {
            watcher.stop()
            watchers.removeValue(forKey: target)
        }
    }

    /// The tab the user last focused in any window (`TerminalBridge.restoreTabState`).
    private nonisolated(unsafe) static var focusedTab: UUID?

    static let focusedInterval: TimeInterval = 1
    static let backgroundInterval: TimeInterval = 5

    static func setFocusedTab(_ tabID: UUID?) {
        lock.withLock { focusedTab = tabID }
    }

    static func tickInterval(registeredTabs: some Sequence<UUID>, focused: UUID?) -> TimeInterval {
        guard let focused, registeredTabs.contains(focused) else { return backgroundInterval }
        return focusedInterval
    }

    let session: RemoteSessionType
    /// Guards `process` and `stopped` — start() writes them from the caller's
    /// thread, the reader launches on readerQueue, stop() may run from
    /// releaseIfUnused or deinit.
    private let processLock = NSLock()
    private var process: Process?
    private var stopped = false
    private let watcherQueue = DispatchQueue(label: "com.boo.cwd-watcher", qos: .utility)
    private let readerQueue = DispatchQueue(label: "com.boo.cwd-reader", qos: .utility)
    /// Each newline written here makes the script scan once. Access on watcherQueue.
    private var tickPipe: Pipe?
    private lazy var tickTimer = AdaptiveTimer(queue: watcherQueue) { [weak self] in self?.tick() }

    /// Tab registrations: paneID → (assignedPID, callback).
    /// Access only on watcherQueue.
    private(set) var tabCallbacks: [UUID: (pid: String?, onChange: @Sendable (String) -> Void)] = [:]

    /// Current PID→CWD map from the latest poll.
    private var pidCwdMap: [String: String] = [:]

    /// PIDs already assigned to tabs.
    private var assignedPIDs: Set<String> = []

    private init(session: RemoteSessionType) {
        self.session = session
    }

    /// Register a tab to receive CWD updates. The tab gets the newest unassigned PID.
    func registerTab(paneID: UUID, onChange: @escaping @Sendable (String) -> Void) {
        watcherQueue.async { [weak self] in
            guard let self else { return }
            let existingPID = self.tabCallbacks[paneID]?.pid
            self.tabCallbacks[paneID] = (pid: existingPID, onChange: onChange)
            remoteLog(
                "[CwdWatcher] registerTab: pane=\(paneID) existingPID=\(existingPID ?? "none") totalTabs=\(self.tabCallbacks.count) knownPIDs=\(self.pidCwdMap.count)"
            )

            // If PIDs are already known, try to assign one immediately.
            // Otherwise, the next processPollBatch will handle it.
            self.tryAssignPID(paneID: paneID)
        }
    }

    /// Try to assign an unassigned PID to a tab. Called on watcherQueue.
    private func tryAssignPID(paneID: UUID) {
        guard let entry = tabCallbacks[paneID], entry.pid == nil else { return }
        guard !pidCwdMap.isEmpty else { return }
        let unassignedPIDs = Set(pidCwdMap.keys).subtracting(assignedPIDs)
        if let bestPID = unassignedPIDs.sorted(by: { Int($0) ?? 0 > Int($1) ?? 0 }).first {
            tabCallbacks[paneID] = (pid: bestPID, onChange: entry.onChange)
            assignedPIDs.insert(bestPID)
            remoteLog("[CwdWatcher] assigned PID \(bestPID) to pane \(paneID)")
            if let cwd = pidCwdMap[bestPID] {
                entry.onChange(cwd)
            }
        }
    }

    /// Unregister a tab. Frees its PID for reassignment.
    func unregisterTab(paneID: UUID) {
        watcherQueue.async { [weak self] in
            guard let self else { return }
            if let entry = self.tabCallbacks.removeValue(forKey: paneID), let pid = entry.pid {
                self.assignedPIDs.remove(pid)
            }
            remoteLog("[CwdWatcher] unregisterTab: pane=\(paneID) remainingTabs=\(self.tabCallbacks.count)")
        }
    }

    /// The watch script: per line on stdin, list all PTY PIDs and their CWDs,
    /// one per line. The host paces it, so no in-container sleep.
    private static let watchScript = """
        while read _; do
            for p in /proc/[0-9]*; do
                pid=${p##*/}
                [ "$pid" = 1 ] || [ "$pid" = $$ ] && continue
                t=$(readlink $p/fd/0 2>/dev/null)
                case $t in /dev/pts/*)
                    c=$(readlink $p/cwd 2>/dev/null)
                    [ -n "$c" ] && echo "$pid $c"
                ;; esac
            done
            echo "---"
        done
        """

    func start() {
        guard case .container(let target, let tool) = session else { return }
        guard let binary = RemoteExplorer.findBinary(tool.rawValue) else {
            remoteLog("[CwdWatcher] \(tool.rawValue) binary not found")
            return
        }

        remoteLog("[CwdWatcher] starting shared watcher for target=\(target)")

        let proc = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        // A tick after the container went away must fail with EPIPE, not kill Boo.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["exec", "-i", target, "sh", "-c", Self.watchScript]
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = stdin
        processLock.lock()
        self.process = proc
        processLock.unlock()

        let fileHandle = stdout.fileHandleForReading

        readerQueue.async { [weak self] in
            // Launch under the lock so stop() either sees a not-yet-launched
            // watcher (and skips terminate) or a running process — never a
            // Process that terminate() would throw on.
            if let self {
                self.processLock.lock()
                if self.stopped {
                    self.processLock.unlock()
                    return
                }
                do {
                    try proc.run()
                } catch {
                    self.process = nil
                    self.processLock.unlock()
                    remoteLog("[CwdWatcher] failed to start: \(error)")
                    return
                }
                self.processLock.unlock()
                self.watcherQueue.async { self.startTicking(stdin) }
            } else {
                return
            }

            var buffer = Data()
            var currentBatch: [(pid: String, cwd: String)] = []

            while proc.isRunning {
                let data = fileHandle.availableData
                if data.isEmpty { break }
                buffer.append(data)

                while let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<newlineIdx]
                    buffer = buffer[buffer.index(after: newlineIdx)...]
                    guard
                        let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    else { continue }

                    if line == "---" {
                        // End of one poll cycle — process the batch on watcherQueue
                        let batch = currentBatch
                        if let self { watcherQueue.async { self.processPollBatch(batch) } }
                        currentBatch = []
                    } else {
                        let parts = line.split(separator: " ", maxSplits: 1)
                        if parts.count == 2 {
                            let pid = String(parts[0])
                            let cwd = String(parts[1])
                            if cwd.hasPrefix("/") {
                                currentBatch.append((pid, cwd))
                            }
                        }
                    }
                }
            }
            remoteLog("[CwdWatcher] process exited")
        }
    }

    /// Called on watcherQueue once the process runs.
    private func startTicking(_ pipe: Pipe) {
        guard !isStopped else { return }
        tickPipe = pipe
        tick()
    }

    /// Asks the script for one scan, then re-paces the timer for the current focus.
    private func tick() {
        guard let fd = tickPipe?.fileHandleForWriting.fileDescriptor else { return }
        var newline = UInt8(ascii: "\n")
        if write(fd, &newline, 1) < 0 && errno == EPIPE {
            stopTicking()
            return
        }
        let interval = Self.tickInterval(
            registeredTabs: tabCallbacks.keys, focused: Self.lock.withLock { Self.focusedTab })
        tickTimer.schedule(interval: interval)
    }

    private func stopTicking() {
        tickTimer.cancel()
        try? tickPipe?.fileHandleForWriting.close()
        tickPipe = nil
    }

    private var isStopped: Bool { processLock.withLock { stopped } }

    /// Process one poll batch: update PID map, assign PIDs to tabs, report changes.
    private func processPollBatch(_ batch: [(pid: String, cwd: String)]) {
        let newMap = Dictionary(batch.map { ($0.pid, $0.cwd) }, uniquingKeysWith: { _, last in last })
        let oldMap = pidCwdMap
        pidCwdMap = newMap

        // Re-derive from tabCallbacks — the source of truth — so a PID can
        // never stay reserved after its tab is gone.
        assignedPIDs = Set(tabCallbacks.compactMap { $0.value.pid })

        // Find new PIDs (just appeared) and assign them to tabs that need a PID
        let newPIDs = Set(newMap.keys).subtracting(Set(oldMap.keys))
        for newPID in newPIDs.sorted(by: { Int($0) ?? 0 > Int($1) ?? 0 }) {
            // Find a tab without an assigned PID
            if let unassigned = tabCallbacks.first(where: { $0.value.pid == nil }) {
                tabCallbacks[unassigned.key] = (pid: newPID, onChange: unassigned.value.onChange)
                assignedPIDs.insert(newPID)
                remoteLog("[CwdWatcher] assigned PID \(newPID) to pane \(unassigned.key)")
                // Report initial CWD
                if let cwd = newMap[newPID] {
                    unassigned.value.onChange(cwd)
                }
            }
        }

        // Report CWD changes for assigned PIDs
        for (paneID, entry) in tabCallbacks {
            guard let pid = entry.pid else { continue }
            guard let cwd = newMap[pid] else {
                // PID gone — unassign so it can be reassigned
                tabCallbacks[paneID] = (pid: nil, onChange: entry.onChange)
                assignedPIDs.remove(pid)
                remoteLog("[CwdWatcher] PID \(pid) gone for pane \(paneID)")
                continue
            }
            if let oldCwd = oldMap[pid], oldCwd != cwd {
                entry.onChange(cwd)
            }
        }

        // Try to assign PIDs to any tabs that still don't have one
        for (paneID, _) in tabCallbacks where tabCallbacks[paneID]?.pid == nil {
            tryAssignPID(paneID: paneID)
        }
    }

    func stop() {
        remoteLog("[CwdWatcher] stopping shared watcher")
        processLock.lock()
        stopped = true
        let proc = process
        process = nil
        processLock.unlock()
        // Safe: the reader launches under processLock and checks `stopped`
        // first, so a non-nil proc here is either launched or never will be.
        // The next tick then fails with EPIPE and stops the timer.
        if let proc, proc.isRunning { proc.terminate() }
    }

    deinit {
        stop()
    }
}
