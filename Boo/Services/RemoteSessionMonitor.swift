import Foundation

/// Polls process trees to detect SSH/Docker child processes for tracked panes.
/// Fires `onSessionChanged` only on state transitions.
/// For container sessions, also polls the container's CWD via /proc.
final class RemoteSessionMonitor: @unchecked Sendable {
    struct TrackedPane {
        var shellPID: pid_t
        var lastSession: RemoteSessionType?
        /// True when the session was set by title heuristics, not process tree.
        /// Prevents the process tree poll from clearing it.
        var titleDetected: Bool = false
    }

    private var tracked: [UUID: TrackedPane] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.boo.remote-monitor", qos: .utility)

    /// Tracks which tabs have registered with a container CWD watcher.
    private var containerWatcherTabs: Set<UUID> = []

    /// Called on the main thread when a pane's remote session state changes.
    var onSessionChanged: ((UUID, RemoteSessionType?) -> Void)?

    /// Called on the main thread when a container session's CWD changes.
    var onContainerCwdChanged: (@Sendable (UUID, String) -> Void)?

    /// Called on the main thread when a fresh shell PID is registered for a pane.
    /// `tabID` is the tab that owns the new shell, or nil if unknown.
    var onShellPIDUpdated: ((UUID, pid_t, UUID?) -> Void)?

    func track(paneID: UUID, shellPID: pid_t, tabID: UUID? = nil) {
        debugLog("[Monitor] track: paneID=\(paneID) shellPID=\(shellPID)")
        queue.async { [weak self] in
            self?.tracked[paneID] = TrackedPane(shellPID: shellPID, lastSession: nil)
            self?.ensureTimerRunning()
            DispatchQueue.main.async { [weak self] in
                self?.onShellPIDUpdated?(paneID, shellPID, tabID)
            }
        }
    }

    func untrack(paneID: UUID) {
        queue.async { [weak self] in
            self?.tracked.removeValue(forKey: paneID)
            if self?.tracked.isEmpty == true {
                self?.stopTimer()
            }
        }
    }

    /// Update the shell PID for a pane (e.g. after tab switch).
    func updateShellPID(paneID: UUID, shellPID: pid_t) {
        queue.async { [weak self] in
            guard var entry = self?.tracked[paneID] else { return }
            entry.shellPID = shellPID
            self?.tracked[paneID] = entry
        }
    }

    /// Synchronous query for the last known session state.
    func currentSession(for paneID: UUID) -> RemoteSessionType? {
        queue.sync { tracked[paneID]?.lastSession }
    }

    /// Synchronous query for the shell PID of a tracked pane.
    func shellPID(for paneID: UUID) -> pid_t? {
        guard let pid: pid_t = queue.sync(execute: { tracked[paneID]?.shellPID }),
            pid > 0
        else { return nil }
        return pid
    }

    /// Returns all tracked PIDs except the one for `excludingPane`.
    /// Used to avoid sending images to the wrong pane's shell.
    func otherTrackedPIDs(excluding paneID: UUID) -> Set<pid_t> {
        queue.sync {
            Set(tracked.compactMap { $0.key != paneID ? $0.value.shellPID : nil })
        }
    }

    /// Manually start container CWD polling for a pane whose container session was
    /// detected by title heuristics (the process tree may not find it due to docker
    /// CLI reparenting on macOS).
    func stopContainerCwdWatcher(paneID: UUID, tabID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.tracked[paneID]?.lastSession {
                ContainerCwdWatcher.shared(for: session)?.unregisterTab(paneID: tabID)
                ContainerCwdWatcher.releaseIfUnused(for: session)
            }
            self.containerWatcherTabs.remove(tabID)
        }
    }

    func startContainerCwdPolling(paneID: UUID, tabID: UUID, session: RemoteSessionType) {
        queue.async { [weak self] in
            guard let self else { return }
            if var entry = self.tracked[paneID] {
                if entry.lastSession != session || !entry.titleDetected {
                    entry.lastSession = session
                    entry.titleDetected = true
                    self.tracked[paneID] = entry
                    remoteLog("[Monitor] startContainerCwdPolling: paneID=\(paneID) tabID=\(tabID) session=\(session)")
                }

                // Register this tab with the shared watcher — keyed by tabID
                guard !self.containerWatcherTabs.contains(tabID) else { return }
                self.containerWatcherTabs.insert(tabID)

                let callback = self.onContainerCwdChanged
                ContainerCwdWatcher.shared(for: session)?.registerTab(paneID: tabID) { cwd in
                    DispatchQueue.main.async { callback?(tabID, cwd) }
                }
            }
        }
    }

    /// Live process tree query for a tracked pane. Checks the process tree NOW
    /// (not from the last poll). Runs synchronously on the caller's thread.
    func probeSession(for paneID: UUID) -> RemoteSessionType? {
        let shellPID: pid_t? = queue.sync { tracked[paneID]?.shellPID }
        guard let pid = shellPID, pid > 0 else { return nil }
        return RemoteExplorer.detectRemoteSessionFiltered(shellPID: pid)
    }

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        for paneID in Array(tracked.keys) {
            guard var entry = tracked[paneID] else { continue }
            let session = RemoteExplorer.detectRemoteSessionFiltered(shellPID: entry.shellPID)

            // When a session was detected by title heuristics (titleDetected),
            // don't let a nil process-tree result clear it — docker CLI is often
            // not a direct child of the shell PID on macOS.
            // But if the process tree finds a DIFFERENT session, adopt it.
            // If the process tree finds the SAME session, clear the flag.
            if entry.titleDetected {
                if session == nil {
                    // Process tree can't find it — keep title-detected session, skip transition
                } else if session == entry.lastSession {
                    entry.titleDetected = false
                    tracked[paneID] = entry
                } else {
                    entry.titleDetected = false
                    // Fall through to normal transition handling
                }
            }

            if session != entry.lastSession && !entry.titleDetected {
                debugLog(
                    "[Monitor] transition: shellPID=\(entry.shellPID) \(String(describing: entry.lastSession)) → \(String(describing: session))"
                )
                let previous = entry.lastSession
                entry.lastSession = session
                tracked[paneID] = entry

                // Manage background SSH connections for SSH-based sessions
                if let session, session.isSSHBased, previous == nil {
                    SSHControlManager.shared.ensureConnection(alias: session.sshConnectionTarget) { _ in }
                } else if let previous, previous.isSSHBased, session == nil {
                    SSHControlManager.shared.teardown(alias: previous.sshConnectionTarget)
                }

                // Clean up container CWD state when session ends
                // Note: we can't know the tabID here, but session ending clears the pane-level state.
                if let previous, previous.isContainer, session == nil {
                    // Unregister all tabs for this pane from the watcher
                    let watcher = ContainerCwdWatcher.shared(for: previous)
                    for tabID in self.containerWatcherTabs {
                        watcher?.unregisterTab(paneID: tabID)
                    }
                    self.containerWatcherTabs.removeAll()
                    ContainerCwdWatcher.releaseIfUnused(for: previous)
                }

                let callback = onSessionChanged
                DispatchQueue.main.async {
                    callback?(paneID, session)
                }
            }

            // Container CWD is handled by persistent watchers, not the poll loop.
        }
    }

    // MARK: - Container CWD Command (for testing)

    /// Shell command to list PID and CWD of all PTY processes inside the container.
    static let containerCwdCommand =
        "for p in /proc/[0-9]*; do pid=${p##*/}; [ \"$pid\" = 1 ] || [ \"$pid\" = $$ ] && continue; t=$(readlink $p/fd/0 2>/dev/null); case $t in /dev/pts/*) c=$(readlink $p/cwd 2>/dev/null); [ -n \"$c\" ] && echo \"$pid $c\";; esac; done"

    static var containerCwdCommandForTesting: String { containerCwdCommand }

    deinit {
        stopTimer()
    }
}
