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

    /// Guarded by `connLock`. Mutations happen only on `queue` (which serializes
    /// the connect logic); the lock exists so `socketPath(for:)` /
    /// `connectionState(for:)` can read from the main thread without queueing
    /// behind an in-flight multi-second `ssh` spawn on `queue`.
    private var connections: [String: ManagedConnection] = [:]
    private let connLock = NSLock()

    private func connection(for alias: String) -> ManagedConnection? {
        connLock.lock()
        defer { connLock.unlock() }
        return connections[alias]
    }

    private func setConnection(_ conn: ManagedConnection?, for alias: String) {
        connLock.lock()
        defer { connLock.unlock() }
        connections[alias] = conn
    }

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

    /// Aliases whose in-flight connect may prompt. Touched only on `queue`.
    private var interactiveInFlight: Set<String> = []

    /// Interactive ssh spawns still running (a prompt may be on screen), so quit
    /// can kill them and their askpass dialog instead of orphaning both.
    private static let interactiveSpawns = SpawnRegistry()

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
        guard let conn = connection(for: alias), conn.state == .ready, conn.isManaged else {
            return nil
        }
        return Self.socketFilePath(for: alias)
    }

    /// Current connection state for an alias.
    func connectionState(for alias: String) -> ConnectionState? {
        connection(for: alias)?.state
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
            guard let self, let conn = self.connection(for: alias) else { return }
            if conn.isManaged {
                Self.killMaster(alias: alias)
            }
            self.setConnection(ManagedConnection(state: .failed, isManaged: conn.isManaged), for: alias)
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

    /// Whether the master backing this alias is still alive, via a local `ssh -O check`.
    /// Managed: Boo's own socket. Unmanaged: the user's master at the ControlPath from
    /// their ssh config; a dead one would leave the next command failing with
    /// `Broken pipe`, so the caller re-establishes.
    private static func isMasterAlive(alias: String, isManaged: Bool) -> Bool {
        guard isManaged else { return userMasterAlive(alias) }
        let socketPath = Self.socketFilePath(for: alias)
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        return Self.runSSHCommand(["-o", "ControlPath=\(socketPath)", "-O", "check", alias])
    }

    private static func userMasterAlive(_ alias: String) -> Bool {
        runSSHCommand(["-O", "check", alias], timeout: 5)
    }

    /// Parks `completion` when the alias is already connecting; otherwise marks it
    /// connecting and returns true. Must be called on `queue`.
    private func beginConnecting(_ alias: String, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        if connection(for: alias)?.state == .connecting {
            waiters[alias, default: []].append(completion)
            return false
        }
        setConnection(ManagedConnection(state: .connecting, isManaged: false), for: alias)
        return true
    }

    func ensureConnection(alias: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if let existing = self.connection(for: alias) {
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
                        var refreshed = existing
                        refreshed.lastVerified = now
                        self.setConnection(refreshed, for: alias)
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
                    // instead of reporting failure (below): the connection is very
                    // likely about to succeed, and a spurious `false` makes callers
                    // burn a retry (or surface an error) for a connection that works.
                    break
                case .failed:
                    break  // Retry
                }
            }

            guard self.beginConnecting(alias, completion: completion) else { return }

            // Step 1: Is the user's own ControlMaster (ssh config ControlPath) running?
            // `-O check` is local and only succeeds for a live master. A plain
            // `ssh alias echo ok` also succeeded for key auth without any master,
            // which marked the alias "unmanaged" and made every later listing pay a
            // full SSH handshake.
            if Self.userMasterAlive(alias) {
                debugLog("[SSHControl] Probe succeeded for \(alias) — user's ControlMaster works")
                self.setConnection(
                    ManagedConnection(state: .ready, isManaged: false, lastVerified: booUptime()),
                    for: alias)
                self.finish(alias: alias, success: true, completion: completion)
                return
            }

            // Step 2: Spawn our own master
            self.record(Self.spawnManagedMaster(alias: alias, interactive: false), alias: alias, completion: completion)
        }
    }

    /// Opens a master for `alias` that may prompt: password, key passphrase or 2FA
    /// codes go through a macOS dialog (SSH_ASKPASS). For hosts the BatchMode connect
    /// can't reach; the file explorer's "Connect…" button calls this.
    func connectInteractively(alias: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.connection(for: alias)?.state == .connecting, !self.interactiveInFlight.contains(alias) {
                // A BatchMode attempt is running: its `false` would come back without a
                // prompt ever showing. Wait for it, and prompt only if it failed.
                self.waiters[alias, default: []].append { [weak self] success in
                    if success {
                        completion(true)
                    } else {
                        self?.connectInteractively(alias: alias, completion: completion)
                    }
                }
                return
            }
            guard self.beginConnecting(alias, completion: completion) else { return }
            self.interactiveInFlight.insert(alias)
            // A half-dead master from an earlier attempt would make `ControlMaster=auto`
            // reuse it instead of authenticating again.
            Self.killMaster(alias: alias)
            // Prompts can wait on the user for minutes: keep the serial queue free
            // (teardownAll on quit runs on it). The alias stays `.connecting` meanwhile.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.spawnManagedMaster(alias: alias, interactive: true)
                self.queue.async {
                    self.interactiveInFlight.remove(alias)
                    self.record(result, alias: alias, completion: completion)
                }
            }
        }
    }

    /// Stores a spawn result and resolves everyone waiting on the alias.
    /// Must be called on `queue`.
    private func record(
        _ result: ManagedConnection, alias: String, completion: @escaping @Sendable (Bool) -> Void
    ) {
        setConnection(result, for: alias)
        finish(alias: alias, success: result.state == .ready, completion: completion)
    }

    /// Spawns and verifies Boo's own master for `alias`. Blocks for the ssh run.
    private static func spawnManagedMaster(alias: String, interactive: Bool) -> ManagedConnection {
        let socketPath = Self.socketFilePath(for: alias)
        debugLog("[SSHControl] Spawning \(interactive ? "interactive " : "")master for \(alias) at \(socketPath)")

        var environment: [String: String]?
        if interactive {
            guard let askpass = Self.installAskpass() else {
                return ManagedConnection(state: .failed, isManaged: false)
            }
            var env = LoginShellEnvironment.sshEnvironment()
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            environment = env
        }
        let spawnResult = Self.runSSHCommand(
            [
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
                "-o", "BatchMode=\(interactive ? "no" : "yes")",
                "-o", "ConnectTimeout=\(interactive ? 10 : 5)",
                "-o", "StrictHostKeyChecking=accept-new",
                "-N", "-f",
                alias
            ],
            // Prompts wait on the user.
            timeout: interactive ? 180 : 10,
            environment: environment,
            tracked: interactive)

        guard spawnResult else {
            debugLog("[SSHControl] Master spawn failed for \(alias)")
            // No master exists — recording it as managed would make a later
            // teardown try to kill and unlink a socket Boo never created.
            return ManagedConnection(state: .failed, isManaged: false)
        }

        // Step 3: Verify with -O check
        let checkResult = Self.runSSHCommand(["-o", "ControlPath=\(socketPath)", "-O", "check", alias])

        if checkResult {
            debugLog("[SSHControl] Master verified for \(alias)")
            return ManagedConnection(state: .ready, isManaged: true, lastVerified: booUptime())
        }
        debugLog("[SSHControl] Master check failed for \(alias)")
        return ManagedConnection(state: .failed, isManaged: true)
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
        // Callers parked while this alias was `.connecting` would otherwise wait
        // forever — their completion lives only in `waiters` and nothing else
        // flushes it once the connection entry is gone.
        let parked = waiters.removeValue(forKey: alias) ?? []
        if !parked.isEmpty {
            DispatchQueue.main.async {
                for waiter in parked { waiter(false) }
            }
        }

        guard let conn = connection(for: alias) else { return }

        if conn.isManaged {
            Self.killMaster(alias: alias)
        }

        setConnection(nil, for: alias)
        debugLog("[SSHControl] Torn down \(alias)")
    }

    /// Tear down all managed connections (app quit).
    ///
    /// Called from `applicationWillTerminate`, which must be synchronous — but N
    /// serial `ssh -O exit` calls would stall quit. Kill masters concurrently with
    /// a short deadline, then unlink the sockets unconditionally so a slow exit
    /// can't leave a stale socket behind for the next launch.
    func teardownAll() {
        // A prompt still open at quit: answering it later would start a master
        // nobody owns.
        for process in Self.interactiveSpawns.all() { Self.terminateTree(process) }

        let managed: [String] = queue.sync {
            connLock.lock()
            let aliases = connections.filter { $0.value.isManaged }.map(\.key)
            connections.removeAll()
            connLock.unlock()
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
    private static func runSSHCommand(
        _ args: [String], timeout: TimeInterval = 10, environment: [String: String]? = nil, tracked: Bool = false
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        // The login shell's SSH_AUTH_SOCK (1Password, Secretive, gpg-agent), not launchd's.
        // `-O` control commands only talk to the local socket: no need to wait for it.
        process.environment =
            environment
            ?? (args.contains("-O") ? ProcessInfo.processInfo.environment : LoginShellEnvironment.sshEnvironment())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // A prompting ssh is killed on quit too (see `teardownAll`); the
        // timeout already takes its askpass child down with it.
        if tracked { interactiveSpawns.insert(process) }
        defer { if tracked { interactiveSpawns.remove(process) } }
        guard process.runAndWait(seconds: timeout, escalateAfter: 2) else {
            debugLog("[SSHControl] failed within \(timeout)s: ssh \(args.joined(separator: " "))")
            return false
        }
        return true
    }

    /// SIGTERMs `process` and its descendants (askpass, osascript), children first.
    private static func terminateTree(_ process: Process) {
        guard process.isRunning else { return }
        let pids = ProcessTree.descendants(of: process.processIdentifier, limit: 32)
        for pid in pids.reversed() { kill(pid, SIGTERM) }
    }

    /// Lock-guarded set of running interactive ssh processes.
    private final class SpawnRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]

        func insert(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
        func remove(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = nil } }
        func all() -> [Process] { lock.withLock { Array(processes.values) } }
    }

    /// SSH_ASKPASS helper: shows ssh's prompt (password, passphrase, 2FA code,
    /// confirmation) as a macOS dialog. Cancel exits non-zero, which ssh treats as
    /// a refused prompt. Rewritten on each use so an update reaches it.
    static func installAskpass() -> String? {
        let path = (BooPaths.configDir as NSString).appendingPathComponent("ssh-askpass")
        let script = """
            #!/bin/sh
            # Written by Boo: SSH_ASKPASS helper for the remote file explorer.
            prompt="${1:-Password:}"
            case "$SSH_ASKPASS_PROMPT" in
            confirm)
                exec /usr/bin/osascript -e 'on run argv' \\
                    -e 'display dialog (item 1 of argv) with title "Boo SSH" buttons {"Cancel", "OK"} default button "OK"' \\
                    -e 'return ""' -e 'end run' "$prompt" >/dev/null ;;
            none)
                exec /usr/bin/osascript -e 'on run argv' \\
                    -e 'display dialog (item 1 of argv) with title "Boo SSH" buttons {"OK"} default button "OK"' \\
                    -e 'return ""' -e 'end run' "$prompt" >/dev/null ;;
            esac
            hidden=true
            case "$prompt" in *"(yes/no"*) hidden=false ;; esac
            exec /usr/bin/osascript -e 'on run argv' \\
                -e 'set r to display dialog (item 1 of argv) default answer "" hidden answer ((item 2 of argv) is "true") with title "Boo SSH" buttons {"Cancel", "OK"} default button "OK"' \\
                -e 'return text returned of r' -e 'end run' "$prompt" "$hidden"

            """
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        } catch {
            debugLog("[SSHControl] askpass install failed: \(error)")
            return nil
        }
    }

    #if DEBUG
        /// Set connection state directly for testing.
        func setTestState(alias: String, state: ConnectionState, isManaged: Bool = true) {
            queue.sync {
                setConnection(ManagedConnection(state: state, isManaged: isManaged), for: alias)
            }
        }

        /// Clear all connection state for testing.
        func clearTestState() {
            queue.sync {
                connLock.lock()
                connections.removeAll()
                connLock.unlock()
                owners.removeAll()
                waiters.removeAll()
                interactiveInFlight.removeAll()
            }
        }

        /// Resolve a `.connecting` alias as if its spawn returned, for testing.
        func resolveForTesting(alias: String, success: Bool) {
            queue.sync {
                let result = ManagedConnection(state: success ? .ready : .failed, isManaged: true)
                record(result, alias: alias) { _ in }
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
