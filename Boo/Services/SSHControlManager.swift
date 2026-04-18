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
    }

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

    /// Ensure a background SSH master connection exists for the given alias.
    /// Calls completion(true) on success, completion(false) on failure. Always on main thread.
    func ensureConnection(alias: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if let existing = self.connections[alias] {
                switch existing.state {
                case .ready:
                    DispatchQueue.main.async { completion(true) }
                    return
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
                self.connections[alias] = ManagedConnection(state: .ready, isManaged: false)
                DispatchQueue.main.async { completion(true) }
                return
            }

            // Step 2: Spawn our own master
            let socketPath = Self.socketFilePath(for: alias)
            debugLog("[SSHControl] Spawning master for \(alias) at \(socketPath)")

            let spawnResult = Self.runSSHCommand([
                "-o", "ControlMaster=yes",
                "-o", "ControlPath=\(socketPath)",
                "-o", "ControlPersist=yes",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                "-N", "-f",
                alias
            ])

            guard spawnResult else {
                debugLog("[SSHControl] Master spawn failed for \(alias)")
                self.connections[alias] = ManagedConnection(state: .failed, isManaged: true)
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
                self.connections[alias] = ManagedConnection(state: .ready, isManaged: true)
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
                let socketPath = Self.socketFilePath(for: alias)
                // Send exit command to master
                _ = Self.runSSHCommand([
                    "-o", "ControlPath=\(socketPath)",
                    "-O", "exit",
                    alias
                ])
                // Clean up socket file
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            self.connections.removeValue(forKey: alias)
            debugLog("[SSHControl] Torn down \(alias)")
        }
    }

    /// Tear down all managed connections (app quit).
    func teardownAll() {
        queue.sync {
            let aliases = Array(connections.keys)
            for alias in aliases {
                guard let conn = connections[alias] else { continue }
                if conn.isManaged {
                    let socketPath = Self.socketFilePath(for: alias)
                    _ = Self.runSSHCommand([
                        "-o", "ControlPath=\(socketPath)",
                        "-O", "exit",
                        alias
                    ])
                    try? FileManager.default.removeItem(atPath: socketPath)
                }
            }
            connections.removeAll()
            debugLog("[SSHControl] All connections torn down")
        }
    }

    // MARK: - Helpers

    private static func sanitize(_ alias: String) -> String {
        alias.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    static func socketFilePath(for alias: String) -> String {
        (BooPaths.sshSocketsDir as NSString).appendingPathComponent("boo-cm-\(sanitize(alias))")
    }

    /// Run an SSH command synchronously. Returns true if exit status == 0.
    private static func runSSHCommand(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            debugLog("[SSHControl] process.run() exception: \(error)")
            return false
        }
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
