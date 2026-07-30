import Foundation

/// Manages per-session background SSH master connections with Boo-owned sockets.
/// Enables the remote file tree to multiplex commands over a persistent connection
/// without requiring ControlMaster in the user's ~/.ssh/config.
final class SSHControlManager: @unchecked Sendable {
    static let shared = SSHControlManager()

    enum ConnectionState {
        case connecting
        case ready
        case failed
    }

    private struct ManagedConnection {
        var state: ConnectionState
        /// Whether Boo spawned the master (vs reusing user's existing ControlMaster).
        var isManaged: Bool
        /// Uptime (seconds) of the last successful liveness probe, so a hot path
        /// hitting `.ready` repeatedly doesn't pay an SSH round-trip every call.
        var lastVerified: TimeInterval = 0
    }

    /// How long a successful liveness probe is trusted before re-probing.
    /// Managed masters use a cheap local `-O check`; unmanaged ones cost a full
    /// network round-trip, so both benefit from not probing on every retry tick.
    private static let livenessTTL: TimeInterval = 5

    private var connections: [String: ManagedConnection] = [:]
    private let queue = DispatchQueue(label: "com.boo.ssh-control", qos: .utility)

    private init() {
        cleanStaleSockets()
    }

    /// Socket path for a given alias, or nil if no managed connection exists.
    /// Returns nil for unmanaged connections (user's own ControlMaster) — SSH will
    /// find the user's socket automatically via their ~/.ssh/config.
    func socketPath(for alias: String) -> String? {
        let conn = queue.sync { connections[alias] }
        guard let conn, conn.state == .ready, conn.isManaged else { return nil }
        return Self.socketFilePath(for: alias)
    }

    /// Current connection state for an alias.
    func connectionState(for alias: String) -> ConnectionState? {
        queue.sync { connections[alias]?.state }
    }

    /// Stderr fragments that mean the transport is gone, not that the remote command
    /// failed. Kept here because the manager owns connection lifecycle — a consumer
    /// shouldn't have to know which OpenSSH messages are fatal.
    private static let transportFailureMarkers = [
        "Broken pipe", "Connection closed", "Connection reset", "Connection timed out"
    ]

    /// Report a failed command run over this alias. The manager decides whether the
    /// failure was the command's or the connection's, and demotes only in the latter
    /// case — a remote `ls` on a missing directory must not tear down the master.
    func reportFailure(alias: String, stderr: String) {
        guard Self.transportFailureMarkers.contains(where: stderr.contains) else { return }
        markFailed(alias: alias)
    }

    /// Demote a connection that reported `.ready` but whose commands are failing.
    ///
    /// `ssh -O check` can say a master is alive while every command over it fails
    /// (auth broken server-side, remote shell wedged). Without this, state stays
    /// `.ready` forever and callers burn their retry budget against a dead link.
    func markFailed(alias: String) {
        queue.async { [weak self] in
            guard let self, let conn = self.connections[alias] else { return }
            if conn.isManaged {
                Self.killMaster(alias: alias)
            }
            self.connections[alias] = ManagedConnection(state: .failed, isManaged: conn.isManaged)
            debugLog("[SSHControl] \(alias) marked failed — will re-establish on next request")
        }
    }

    /// Kill a managed master: ask it to exit, then remove its socket file.
    /// Safe to call on an already-dead master (`-O exit` just fails silently).
    /// `unlink: false` lets a bulk caller drop the sockets itself after fanning out.
    private static func killMaster(alias: String, timeout: TimeInterval = 10, unlink: Bool = true) {
        let socketPath = Self.socketFilePath(for: alias)
        _ = Self.runSSHCommand(
            ["-o", "ControlPath=\(socketPath)", "-O", "exit", alias], timeout: timeout)
        if unlink { try? FileManager.default.removeItem(atPath: socketPath) }
    }

    /// Whether the master backing this alias is still alive.
    /// Managed: probe Boo's own socket with `ssh -O check`.
    /// Unmanaged: we don't own (or know) the user's socket path, but a stale
    /// `.ready` user master still leaves the next command failing with a
    /// `Broken pipe`. So probe with a cheap real command — if the user's
    /// ControlMaster is dead, this returns false and the caller re-establishes.
    private static func isMasterAlive(alias: String, isManaged: Bool) -> Bool {
        guard isManaged else {
            return Self.runSSHCommand([
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                alias, "true"
            ])
        }
        let socketPath = Self.socketFilePath(for: alias)
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        return Self.runSSHCommand(["-o", "ControlPath=\(socketPath)", "-O", "check", alias])
    }

    /// Ensure a background SSH master connection exists for the given alias.
    /// Calls completion(true) on success, completion(false) on failure. Always on main thread.
    func ensureConnection(alias: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if let existing = self.connections[alias] {
                switch existing.state {
                case .ready:
                    // Don't trust a stale `.ready` — the master may have died since
                    // (network blip, server reboot, ControlPersist timeout). Verify
                    // the socket is still alive before short-circuiting, but trust a
                    // recent probe: retry ticks call this repeatedly and an unmanaged
                    // probe is a full network round-trip.
                    let now = booUptime()
                    if now - existing.lastVerified < Self.livenessTTL {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    if Self.isMasterAlive(alias: alias, isManaged: existing.isManaged) {
                        self.connections[alias]?.lastVerified = now
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    debugLog("[SSHControl] \(alias) was .ready but master is dead — re-establishing")
                    if existing.isManaged {
                        Self.killMaster(alias: alias)
                    }
                // Fall through to re-establish.
                case .connecting:
                    // Already in progress — caller should retry
                    DispatchQueue.main.async { completion(false) }
                    return
                case .failed:
                    break  // Retry
                }
            }

            self.connections[alias] = ManagedConnection(state: .connecting, isManaged: false)

            // Step 1: Quick probe — does the user's own ControlMaster work?
            let probeResult = Self.runSSHCommand([
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                alias, "echo", "ok"
            ])
            if probeResult {
                debugLog("[SSHControl] Probe succeeded for \(alias) — user's ControlMaster works")
                self.connections[alias] = ManagedConnection(
                    state: .ready, isManaged: false, lastVerified: booUptime())
                DispatchQueue.main.async { completion(true) }
                return
            }

            // Step 2: Spawn our own master
            let socketPath = Self.socketFilePath(for: alias)
            debugLog("[SSHControl] Spawning master for \(alias) at \(socketPath)")

            let spawnResult = Self.runSSHCommand([
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(socketPath)",
                // Finite persist so an idle/orphaned master gets reaped instead of
                // lingering with a dead socket forever.
                "-o", "ControlPersist=30m",
                // Keepalives so a master whose TCP died (NAT/firewall idle timeout,
                // server reboot) tears itself down rather than leaving a stale socket
                // that future commands hang/fail against.
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                "-N", "-f",
                alias
            ])

            guard spawnResult else {
                debugLog("[SSHControl] Master spawn failed for \(alias)")
                // No master exists — recording it as managed would make a later
                // teardown try to kill and unlink a socket Boo never created.
                self.connections[alias] = ManagedConnection(state: .failed, isManaged: false)
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Step 3: Verify with -O check
            let checkResult = Self.runSSHCommand([
                "-o", "ControlPath=\(socketPath)",
                "-O", "check",
                alias
            ])

            if checkResult {
                debugLog("[SSHControl] Master verified for \(alias)")
                self.connections[alias] = ManagedConnection(
                    state: .ready, isManaged: true, lastVerified: booUptime())
                DispatchQueue.main.async { completion(true) }
            } else {
                debugLog("[SSHControl] Master check failed for \(alias)")
                self.connections[alias] = ManagedConnection(state: .failed, isManaged: true)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Tear down the master connection for an alias.
    func teardown(alias: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let conn = self.connections[alias] else { return }

            if conn.isManaged {
                Self.killMaster(alias: alias)
            }

            self.connections.removeValue(forKey: alias)
            debugLog("[SSHControl] Torn down \(alias)")
        }
    }

    /// Tear down all managed connections (app quit).
    ///
    /// Called from `applicationWillTerminate`, which must be synchronous — but N
    /// serial `ssh -O exit` calls would stall quit. Kill masters concurrently with
    /// a short deadline, then unlink the sockets unconditionally so a slow exit
    /// can't leave a stale socket behind for the next launch.
    func teardownAll() {
        let managed: [String] = queue.sync {
            let aliases = connections.filter { $0.value.isManaged }.map(\.key)
            connections.removeAll()
            return aliases
        }
        guard !managed.isEmpty else { return }

        let group = DispatchGroup()
        for alias in managed {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.killMaster(alias: alias, timeout: 2, unlink: false)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
        for alias in managed {
            try? FileManager.default.removeItem(atPath: Self.socketFilePath(for: alias))
        }
        debugLog("[SSHControl] All connections torn down (\(managed.count))")
    }

    // MARK: - Helpers

    private static func sanitize(_ alias: String) -> String {
        alias.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    static func socketFilePath(for alias: String) -> String {
        (BooPaths.sshSocketsDir as NSString).appendingPathComponent("boo-cm-\(sanitize(alias))")
    }

    /// Run an SSH command synchronously with a hard wall-clock timeout.
    /// Returns true if exit status == 0.
    ///
    /// The timeout is load-bearing: `ConnectTimeout` only bounds TCP connect, not
    /// auth. A wedged `ssh` (stuck agent, keyboard-interactive slipping past
    /// BatchMode) would otherwise block this serial queue forever — and
    /// `socketPath(for:)` / `connectionState(for:)` are `queue.sync`, called from
    /// the main thread, so that becomes a UI hang.
    private static func runSSHCommand(_ args: [String], timeout: TimeInterval = 10) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        guard process.runAndWait(seconds: timeout, escalateAfter: 2) else {
            debugLog("[SSHControl] failed within \(timeout)s: ssh \(args.joined(separator: " "))")
            return false
        }
        return true
    }

    #if DEBUG
        /// Set connection state directly for testing.
        func setTestState(alias: String, state: ConnectionState, isManaged: Bool = true) {
            queue.sync { connections[alias] = ManagedConnection(state: state, isManaged: isManaged) }
        }

        /// Clear all connection state for testing.
        func clearTestState() {
            queue.sync { connections.removeAll() }
        }
    #endif

    /// Remove stale sockets from a previous crash.
    private func cleanStaleSockets() {
        let dir = BooPaths.sshSocketsDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for file in files where file.hasPrefix("boo-cm-") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
