import Foundation

/// Polls process trees to detect SSH/Docker child processes for tracked panes.
/// Fires `onSessionChanged` only on state transitions.
final class RemoteSessionMonitor {
    struct TrackedPane {
        var shellPID: pid_t
        var lastSession: RemoteSessionType?
    }

    private var tracked: [UUID: TrackedPane] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.exterm.remote-monitor", qos: .utility)

    /// Called on the main thread when a pane's remote session state changes.
    var onSessionChanged: ((UUID, RemoteSessionType?) -> Void)?

    func track(paneID: UUID, shellPID: pid_t) {
        NSLog("[Monitor] track: paneID=\(paneID) shellPID=\(shellPID)")
        queue.async { [weak self] in
            self?.tracked[paneID] = TrackedPane(shellPID: shellPID, lastSession: nil)
            self?.ensureTimerRunning()
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
        for (paneID, var entry) in tracked {
            let session = RemoteExplorer.detectRemoteSessionFiltered(shellPID: entry.shellPID)
            if session != entry.lastSession {
                NSLog(
                    "[Monitor] transition: shellPID=\(entry.shellPID) \(String(describing: entry.lastSession)) → \(String(describing: session))"
                )
                let previous = entry.lastSession
                entry.lastSession = session
                tracked[paneID] = entry

                // Manage background SSH connections for the remote file tree
                if case .ssh(let host, _) = session, previous == nil {
                    SSHControlManager.shared.ensureConnection(alias: host) { _ in }
                } else if case .ssh(let prevHost, _) = previous, session == nil {
                    SSHControlManager.shared.teardown(alias: prevHost)
                }

                let callback = onSessionChanged
                DispatchQueue.main.async {
                    callback?(paneID, session)
                }
            }
        }
    }

    deinit {
        stopTimer()
    }
}
