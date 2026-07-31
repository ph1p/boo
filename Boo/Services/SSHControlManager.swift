import CryptoKit
import Foundation

/// Thread-safe accumulator for aliases whose master confirmed exit during teardown.
/// A reference box, not a captured `var`, so the concurrent teardown closures mutate
/// shared state without tripping Sendable capture diagnostics.
private final class ExitedAliases: @unchecked Sendable {
    private let lock = NSLock()
    private var aliases: Set<String> = []

    func insert(_ alias: String) {
        lock.lock()
        aliases.insert(alias)
        lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return aliases
    }
}

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

    /// Panes currently relying on each alias's master, keyed by alias.
    ///
    /// A master is shared: several panes can be SSH'd into the same host at once.
    /// Tearing it down when any one of them closes would kill the connection under
    /// the others, so teardown only happens once the last owner releases it.
    ///
    /// A set of owners rather than a counter — registering the same pane twice can't
    /// inflate it, and a pane re-registering after a missed release self-corrects.
    private var owners: [String: Set<UUID>] = [:]

    /// Completions parked while an alias is `.connecting`, flushed once it resolves.
    private var waiters: [String: [@Sendable (Bool) -> Void]] = [:]

    private let queue = DispatchQueue(label: "com.boo.ssh-control", qos: .utility)

    /// Resolve `alias` for the calling completion and everyone queued behind it.
    /// Must be called on `queue`.
    private func finish(alias: String, success: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let parked = waiters.removeValue(forKey: alias) ?? []
        DispatchQueue.main.async {
            completion(success)
            for waiter in parked { waiter(success) }
        }
    }

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
    /// Returns whether `-O exit` succeeded, so a bulk caller can tell a confirmed
    /// shutdown from one that merely timed out.
    @discardableResult
    private static func killMaster(alias: String, timeout: TimeInterval = 10, unlink: Bool = true) -> Bool {
        let socketPath = Self.socketFilePath(for: alias)
        let exited = Self.runSSHCommand(
            ["-o", "ControlPath=\(socketPath)", "-O", "exit", alias], timeout: timeout)
        if unlink { try? FileManager.default.removeItem(atPath: socketPath) }
        return exited
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
                        self.finish(alias: alias, success: true, completion: completion)
                        return
                    }
                    if Self.isMasterAlive(alias: alias, isManaged: existing.isManaged) {
                        self.connections[alias]?.lastVerified = now
                        self.finish(alias: alias, success: true, completion: completion)
                        return
                    }
                    debugLog("[SSHControl] \(alias) was .ready but master is dead — re-establishing")
                    if existing.isManaged {
                        Self.killMaster(alias: alias)
                    }
                // Fall through to re-establish.
                case .connecting:
                    // Another caller is already establishing this master. Queue up
                    // instead of reporting failure: the connection is very likely
                    // about to succeed, and a spurious `false` makes callers burn a
                    // retry (or surface an error) for a connection that works.
                    self.waiters[alias, default: []].append(completion)
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
                self.finish(alias: alias, success: true, completion: completion)
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
                self.finish(alias: alias, success: false, completion: completion)
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
                self.finish(alias: alias, success: true, completion: completion)
            } else {
                debugLog("[SSHControl] Master check failed for \(alias)")
                self.connections[alias] = ManagedConnection(state: .failed, isManaged: true)
                self.finish(alias: alias, success: false, completion: completion)
            }
        }
    }

    /// Register `owner` as relying on `alias`, establishing the master if needed.
    ///
    /// Prefer this over bare `ensureConnection` for anything tied to a pane's
    /// lifetime: it pairs with `release(alias:owner:)` so a shared master survives
    /// until the last pane using it goes away.
    func acquire(alias: String, owner: UUID, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        queue.async { [weak self] in
            self?.owners[alias, default: []].insert(owner)
        }
        ensureConnection(alias: alias, completion: completion)
    }

    /// Drop `owner`'s claim on `alias`, tearing the master down only if it was the last.
    func release(alias: String, owner: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.owners[alias]?.remove(owner)
            guard self.owners[alias]?.isEmpty ?? true else {
                debugLog(
                    "[SSHControl] \(alias) still in use by \(self.owners[alias]?.count ?? 0) pane(s) — keeping master")
                return
            }
            self.owners.removeValue(forKey: alias)
            self.teardownLocked(alias: alias)
        }
    }

    /// Tear down the master connection for an alias, ignoring owners.
    /// Use `release(alias:owner:)` for pane-scoped teardown.
    func teardown(alias: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.owners.removeValue(forKey: alias)
            self.teardownLocked(alias: alias)
        }
    }

    /// Teardown body. Must be called on `queue`.
    private func teardownLocked(alias: String) {
        guard let conn = connections[alias] else { return }

        if conn.isManaged {
            Self.killMaster(alias: alias)
        }

        connections.removeValue(forKey: alias)
        debugLog("[SSHControl] Torn down \(alias)")
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
            owners.removeAll()
            return aliases
        }
        guard !managed.isEmpty else { return }

        let group = DispatchGroup()
        let exitedBox = ExitedAliases()
        for alias in managed {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if Self.killMaster(alias: alias, timeout: 2, unlink: false) {
                    exitedBox.insert(alias)
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)

        // Unlink only the masters that actually exited. A master still shutting down
        // when the deadline passes keeps its socket: removing it would strand a live
        // process with an unreachable socket, and the next launch's stale-socket
        // sweep cleans it up once it's genuinely dead.
        let confirmed = exitedBox.snapshot()
        for alias in confirmed {
            try? FileManager.default.removeItem(atPath: Self.socketFilePath(for: alias))
        }
        debugLog(
            "[SSHControl] All connections torn down (\(confirmed.count)/\(managed.count) confirmed exited)")
    }

    // MARK: - Helpers

    private static func sanitize(_ alias: String) -> String {
        alias.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    /// Socket filename for an alias.
    ///
    /// Sanitizing alone is lossy — `host.example.com`, `host-example-com` and
    /// `user@host.example.com` all collapse to the same string, so two different
    /// hosts would share one socket and get each other's connection. A hash of the
    /// full alias disambiguates; the sanitized prefix is kept only so the socket
    /// directory stays readable when debugging.
    ///
    /// The name is also length-capped: ControlPath feeds a sockaddr_un, whose path
    /// is limited to ~104 bytes on macOS, and a long `user@host` would silently
    /// overflow it.
    private static func socketFileName(for alias: String) -> String {
        let digest = SHA256.hash(data: Data(alias.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        let prefix = sanitize(alias).prefix(32)
        return "boo-cm-\(prefix)-\(hash)"
    }

    static func socketFilePath(for alias: String) -> String {
        (BooPaths.sshSocketsDir as NSString).appendingPathComponent(socketFileName(for: alias))
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
            queue.sync {
                connections.removeAll()
                owners.removeAll()
                waiters.removeAll()
            }
        }

        /// Number of panes currently holding `alias`, for testing.
        func testOwnerCount(alias: String) -> Int {
            queue.sync { owners[alias]?.count ?? 0 }
        }

        /// Register ownership without establishing a connection, for testing.
        func acquireWithoutConnecting(alias: String, owner: UUID) {
            queue.sync { _ = owners[alias, default: []].insert(owner) }
        }

        /// Wait for the internal queue to drain, for testing.
        func drainForTesting() {
            queue.sync {}
        }
    #endif

    /// Remove sockets left behind by a previous crash.
    ///
    /// Only sockets with no live master are removed. A second Boo instance may be
    /// running against the same directory, and deleting every `boo-cm-*` socket
    /// unconditionally would sever its working connections.
    ///
    /// Runs off the init thread: each probe spawns an `ssh -O check`, which is far
    /// too slow to block startup on.
    private func cleanStaleSockets() {
        let dir = BooPaths.sshSocketsDir
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for file in files where file.hasPrefix("boo-cm-") {
                let path = (dir as NSString).appendingPathComponent(file)
                // `-O check` against the socket itself; the alias is irrelevant since
                // ControlPath fully determines which master answers.
                let alive = Self.runSSHCommand(
                    ["-o", "ControlPath=\(path)", "-O", "check", "boo-stale-probe"], timeout: 2)
                guard !alive else { continue }
                try? FileManager.default.removeItem(atPath: path)
                debugLog("[SSHControl] Removed stale socket \(file)")
            }
        }
    }
}
