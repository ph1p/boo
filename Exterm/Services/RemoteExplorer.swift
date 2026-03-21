import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The type of remote session detected.
enum RemoteSessionType {
    case ssh(host: String, alias: String? = nil)
    case docker(container: String)

    var displayName: String {
        switch self {
        case .ssh(let host, _): return host
        case .docker(let container): return container
        }
    }

    /// The target to use for SSH connections (alias if available, otherwise host).
    /// This matches what the user typed (e.g. "het") and what SSHControlManager keys on.
    var sshConnectionTarget: String {
        switch self {
        case .ssh(let host, let alias): return alias ?? host
        case .docker(let container): return container
        }
    }

    var icon: String {
        switch self {
        case .ssh: return "globe"
        case .docker: return "shippingbox"
        }
    }

    var connectingHint: String {
        switch self {
        case .ssh: return "Establishing SSH connection.\nFile explorer requires key-based auth or SSH agent."
        case .docker: return "Waiting for container shell to start."
        }
    }
}

extension RemoteSessionType: Equatable {
    /// Alias is ignored for equality — prevents false transitions when alias is discovered.
    static func == (lhs: RemoteSessionType, rhs: RemoteSessionType) -> Bool {
        switch (lhs, rhs) {
        case (.ssh(let lhsHost, _), .ssh(let rhsHost, _)):
            return lhsHost == rhsHost
        case (.docker(let lhsContainer), .docker(let rhsContainer)):
            return lhsContainer == rhsContainer
        default:
            return false
        }
    }
}

/// Detects remote sessions (SSH, Docker) and provides file listing.
final class RemoteExplorer {
    struct RemoteEntry {
        let name: String
        let isDirectory: Bool
    }

    // MARK: - Detection

    /// Detect if the shell has a remote child process (SSH or Docker exec).
    static func detectRemoteSession(shellPID: pid_t) -> RemoteSessionType? {
        if let host = detectSSH(shellPID: shellPID) {
            return .ssh(host: host)
        }
        if let container = detectDocker(shellPID: shellPID) {
            return .docker(container: container)
        }
        return nil
    }

    private static func detectSSH(shellPID: pid_t) -> String? {
        guard let pid = findChildProcess(parentPID: shellPID, name: "ssh") else { return nil }
        return parseSSHHost(pid: pid)
    }

    private static func detectDocker(shellPID: pid_t) -> String? {
        guard let pid = findChildProcess(parentPID: shellPID, name: "docker") else { return nil }
        return parseDockerContainer(pid: pid)
    }

    /// Find a child process by name using pgrep.
    /// Find child process by name using proc_listchildpids + proc_name.
    /// Find a descendant process by name, searching recursively up to `maxDepth` levels.
    private static func findChildProcess(parentPID: pid_t, name: String, maxDepth: Int = 4) -> pid_t? {
        let children = childPIDs(of: parentPID)
        for child in children {
            // Try proc_name first (fast, kernel-level)
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
            proc_name(child, &nameBuffer, UInt32(nameBuffer.count))
            let procName = String(cString: nameBuffer)
            if procName.contains(name) { return child }
            // Fallback: proc_name can return empty for PTY child processes on macOS.
            // Use sysctl KERN_PROCARGS2 to get the executable path instead.
            if procName.isEmpty, let args = getProcessArgs(pid: child) {
                let exe = args.split(separator: " ").first.map(String.init) ?? ""
                let base = (exe as NSString).lastPathComponent
                if base.contains(name) { return child }
            }
        }
        // Recurse into children
        if maxDepth > 0 {
            for child in children {
                if let found = findChildProcess(parentPID: child, name: name, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }
        return nil
    }

    /// Extract SSH host from the process command line.
    private static func parseSSHHost(pid: pid_t) -> String? {
        guard let cmdline = getProcessArgs(pid: pid) else { return nil }

        let args = cmdline.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        var host: String?
        var skipNext = false

        for (i, arg) in args.enumerated() {
            if i == 0 { continue }
            if skipNext {
                skipNext = false
                continue
            }
            if arg.hasPrefix("-") {
                let valueOpts: Set<String> = [
                    "-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-w", "-E"
                ]
                if valueOpts.contains(arg) { skipNext = true }
                continue
            }
            host = arg
            break
        }
        return host
    }

    /// Extract Docker container name/ID from `docker exec` command line.
    private static func parseDockerContainer(pid: pid_t) -> String? {
        guard let cmdline = getProcessArgs(pid: pid) else { return nil }

        let args = cmdline.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)

        // Find "exec" subcommand, then parse past options to get container name
        guard let execIdx = args.firstIndex(of: "exec") else { return nil }

        var skipNext = false
        for i in (execIdx + 1)..<args.count {
            let arg = args[i]
            if skipNext {
                skipNext = false
                continue
            }
            if arg.hasPrefix("-") {
                // Docker exec options that take a value
                let valueOpts: Set<String> = ["-e", "--env", "-w", "--workdir", "-u", "--user", "--detach-keys"]
                if valueOpts.contains(arg) { skipNext = true }
                continue
            }
            // First non-option after "exec" is the container
            return arg
        }
        return nil
    }

    // MARK: - Process Tree Helpers

    /// Return all child PIDs of a given parent process.
    /// Note: `proc_listchildpids` returns the count of children (not bytes).
    static func childPIDs(of parent: pid_t) -> [pid_t] {
        // First call with nil buffer returns estimated child count
        let estimate = proc_listchildpids(parent, nil, 0)
        guard estimate > 0 else { return [] }
        // Allocate buffer; pass buffer size in bytes
        let bufCount = max(Int(estimate), 16)
        var pids = [pid_t](repeating: 0, count: bufCount)
        let bufSize = Int32(bufCount * MemoryLayout<pid_t>.size)
        let actual = proc_listchildpids(parent, &pids, bufSize)
        guard actual > 0 else { return [] }
        // Return value is count of children written
        return Array(pids.prefix(Int(actual)))
    }

    /// Walk from a process down single-child chains to find the actual shell.
    /// Ghostty forks: Exterm → login → shell. This walks login → shell.
    /// Stops when: the process has 0 children, >1 children, or is a known shell.
    static func walkToLeafShell(from pid: pid_t) -> pid_t {
        let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "elvish"]
        var current = pid
        for _ in 0..<5 {  // safety limit
            // Check if current process is a shell
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
            proc_name(current, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            // Strip leading "-" (login shells show as "-zsh")
            let cleanName = name.hasPrefix("-") ? String(name.dropFirst()) : name
            if shellNames.contains(cleanName) { return current }

            let children = childPIDs(of: current)
            if children.count == 1 {
                current = children[0]
            } else {
                break
            }
        }
        return current
    }

    /// Check if an SSH process is just a tunnel (not an interactive session).
    /// Tunnels use -N (no remote command), -D (SOCKS), or -L/-R without a trailing command.
    static func isSSHTunnel(pid: pid_t) -> Bool {
        guard let cmdline = getProcessArgs(pid: pid) else { return false }
        let args = cmdline.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        // -N means no remote command — always a tunnel
        if args.contains("-N") { return true }
        // -D (SOCKS proxy) without a trailing host command
        if args.contains("-D") {
            // Check if there's a non-option arg after the host (a remote command)
            return !hasRemoteCommand(args: args)
        }
        return false
    }

    /// Check if ssh args contain a remote command after the host argument.
    private static func hasRemoteCommand(args: [String]) -> Bool {
        var skipNext = false
        var foundHost = false
        for (i, arg) in args.enumerated() {
            if i == 0 { continue }
            if skipNext {
                skipNext = false
                continue
            }
            if arg.hasPrefix("-") {
                let valueOpts: Set<String> = [
                    "-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-w", "-E"
                ]
                if valueOpts.contains(arg) { skipNext = true }
                continue
            }
            if !foundHost {
                foundHost = true
                continue
            }
            // Found an arg after the host — it's a remote command
            return true
        }
        return false
    }

    /// Resolve a Docker container hostname (truncated container ID) to a container name.
    /// Returns nil if the hostname doesn't look like a container ID or docker isn't available.
    private static var dockerHostnameCache: [String: (name: String?, expires: Date)] = [:]

    static func resolveDockerHostname(_ hostname: String) -> String? {
        // Docker container hostnames are typically 12-char hex prefixes
        let cleaned = hostname.lowercased()
        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }

        // Check cache
        if let cached = dockerHostnameCache[cleaned], Date() < cached.expires {
            return cached.name
        }

        // Find docker binary
        var dockerPath: String?
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.fileExists(atPath: path) {
                dockerPath = path
                break
            }
        }
        guard let docker = dockerPath else { return nil }

        let result = runLocalCommand(docker, args: ["ps", "--filter", "id=\(cleaned)", "--format", "{{.Names}}"])
        let name = result?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (name?.isEmpty == false) ? name : nil
        dockerHostnameCache[cleaned] = (name: resolved, expires: Date().addingTimeInterval(30))
        return resolved
    }

    // MARK: - Detection (enhanced)

    /// Detect remote session with SSH tunnel filtering.
    static func detectRemoteSessionFiltered(shellPID: pid_t) -> RemoteSessionType? {
        // Check SSH first
        if let sshPID = findChildProcess(parentPID: shellPID, name: "ssh") {
            if !isSSHTunnel(pid: sshPID) {
                if let host = parseSSHHost(pid: sshPID) {
                    return .ssh(host: host)
                }
            }
        }
        // Check Docker
        if let container = detectDocker(shellPID: shellPID) {
            return .docker(container: container)
        }
        return nil
    }

    // MARK: - ControlMaster Setup

    /// Append ControlMaster config to ~/.ssh/config if not already present.
    /// Returns true on success.
    static func enableControlMaster() -> Bool {
        let configPath = NSHomeDirectory() + "/.ssh/config"
        let fm = FileManager.default

        // Check if already configured
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            if existing.lowercased().contains("controlmaster") {
                return true  // already configured
            }
        }

        // Ensure ~/.ssh directory exists
        let sshDir = NSHomeDirectory() + "/.ssh"
        if !fm.fileExists(atPath: sshDir) {
            try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)
        }

        let block =
            "\n# Added by Exterm — enables SSH connection sharing for file explorer\nHost *\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-%r@%h:%p\n  ControlPersist 10m\n"

        if let handle = FileHandle(forWritingAtPath: configPath) {
            handle.seekToEndOfFile()
            if let data = block.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
            return true
        } else {
            // Config file doesn't exist yet — create it
            return fm.createFile(
                atPath: configPath, contents: block.data(using: .utf8),
                attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: - Home Path Resolution

    /// Cached absolute home paths keyed by session display name.
    private static var homePathCache: [String: String] = [:]

    /// Resolve the remote home directory (`~`) to an absolute path.
    /// Result is cached per session. Calls completion on main thread.
    static func resolveRemoteHome(session: RemoteSessionType, completion: @escaping (String?) -> Void) {
        let key = session.sshConnectionTarget
        if let cached = homePathCache[key] {
            completion(cached)
            return
        }
        // `echo ~` works on bash, zsh, sh, dash, fish, ash (busybox)
        runRemoteCommand(session: session, command: "echo ~") { output in
            let home = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let home = home, !home.isEmpty, home.hasPrefix("/") {
                homePathCache[key] = home
                completion(home)
            } else {
                completion(nil)
            }
        }
    }

    /// Synchronously resolve a tilde-prefixed path using the cached home directory.
    /// Returns nil if the home path isn't cached yet.
    static func resolveTilde(_ path: String, session: RemoteSessionType) -> String? {
        let key = session.sshConnectionTarget
        guard let home = homePathCache[key] else { return nil }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Clear cached home path for a session (call on session end).
    static func clearHomeCache(for session: RemoteSessionType) {
        homePathCache.removeValue(forKey: session.sshConnectionTarget)
    }

    #if DEBUG
        static func clearAllHomeCache() {
            homePathCache.removeAll()
        }
    #endif

    // MARK: - Remote Commands

    /// Get the remote working directory.
    static func getRemoteCwd(session: RemoteSessionType, completion: @escaping (String?) -> Void) {
        runRemoteCommand(session: session, command: "pwd") { output in
            completion(output?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// List directory contents on the remote target.
    /// Completion receives `nil` on connection/command failure, empty array for empty directory.
    static func listRemoteDirectory(
        session: RemoteSessionType, path: String, completion: @escaping ([RemoteEntry]?) -> Void
    ) {
        let cmd = directoryListCommand(for: path)

        runRemoteCommand(session: session, command: cmd) { output in
            guard let output = output else {
                completion(nil)
                return
            }
            guard !output.isEmpty else {
                completion([])
                return
            }

            var entries: [RemoteEntry] = []
            for line in output.split(separator: "\n") {
                var name = String(line)
                let isDir = name.hasSuffix("/")
                if isDir { name = String(name.dropLast()) }
                if let last = name.last, "@*|=".contains(last) { name = String(name.dropLast()) }
                guard !name.isEmpty else { continue }
                entries.append(RemoteEntry(name: name, isDirectory: isDir))
            }
            entries.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            completion(entries)
        }
    }

    static func directoryListCommand(for path: String) -> String {
        "ls -1AF \(shellEscPath(path)) 2>/dev/null"
    }

    // MARK: - Command Execution

    /// Find an existing ControlMaster socket for the given host.
    /// `host` may be "hostname" or "user@hostname".
    static func findControlSocket(host: String) -> String? {
        // Build required search terms: the socket filename must contain the hostname.
        // When user@host is given, require BOTH user and hostname to match,
        // preventing a socket for user@serverA from matching a lookup for user@serverB.
        let lowered = host.lowercased()
        let requiredTerms: [String]
        if let atIdx = lowered.firstIndex(of: "@") {
            let user = String(lowered[..<atIdx])
            let hostname = String(lowered[lowered.index(after: atIdx)...])
            requiredTerms = [user, hostname]
        } else {
            requiredTerms = [lowered]
        }

        // Search common socket directories
        let home = NSHomeDirectory()
        let searchDirs = [
            home + "/.ssh",
            home + "/.ssh/sockets",
            home + "/.ssh/cm",
            "/tmp"
        ]

        let fm = FileManager.default
        for dir in searchDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files {
                let lower = file.lowercased()
                // Socket must contain ALL required terms (both user and hostname)
                guard requiredTerms.allSatisfy({ lower.contains($0) }) else { continue }

                let path = dir + "/" + file
                var statBuf = stat()
                guard stat(path, &statBuf) == 0 else { continue }
                if (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                    return path
                }
            }
        }
        return nil
    }

    private static func runSSH(host: String, command: String, extraArgs: [String] = []) -> String? {
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-n",  // no stdin — prevents password prompts from blocking
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes"
        ]
        // Use Exterm's managed socket if available (enables multiplexing without user config).
        // For hosts with user-configured ControlMaster (or Exterm's auto-enabled config),
        // the SSH client finds the socket automatically — no explicit ControlPath needed.
        if let socket = SSHControlManager.shared.socketPath(for: host) {
            args += ["-o", "ControlPath=\(socket)"]
        }
        args += extraArgs
        args += [host, command]
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog(
                    "[RemoteExplorer] SSH failed: host=\(host) exit=\(process.terminationStatus) stderr=\(stderr.prefix(200))"
                )
                return nil
            }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runRemoteCommand(
        session: RemoteSessionType, command: String, completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch session {
            case .ssh(let host, let alias):
                // Use alias (the SSH config name) if available — matches the managed socket.
                let target = alias ?? host
                let result = runSSH(host: target, command: command)
                DispatchQueue.main.async { completion(result) }

            case .docker(let container):
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()
                // Find docker binary
                var dockerPath = "/usr/local/bin/docker"
                for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
                    if FileManager.default.fileExists(atPath: path) {
                        dockerPath = path
                        break
                    }
                }
                process.executableURL = URL(fileURLWithPath: dockerPath)
                process.arguments = ["exec", container, "sh", "-c", command]
                process.standardOutput = pipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    guard process.terminationStatus == 0 else {
                        NSLog(
                            "[RemoteExplorer] docker exec failed: container=\(container) exit=\(process.terminationStatus) stderr=\(stderr.prefix(200))"
                        )
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    DispatchQueue.main.async { completion(String(data: data, encoding: .utf8)) }
                } catch {
                    NSLog("[RemoteExplorer] docker exec exception: \(error)")
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }

    /// Get process command line arguments using sysctl (no subprocess).
    private static func getProcessArgs(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Skip argc (first 4 bytes)
        guard size > 4 else { return nil }
        let args = buffer.withUnsafeBufferPointer { buf -> String? in
            // Skip argc int
            var offset = MemoryLayout<Int32>.size
            // Skip exec path (null-terminated)
            while offset < size && buf[offset] != 0 { offset += 1 }
            // Skip padding nulls
            while offset < size && buf[offset] == 0 { offset += 1 }
            // Remaining is null-separated args
            var result: [String] = []
            var current = ""
            while offset < size {
                if buf[offset] == 0 {
                    if !current.isEmpty { result.append(current) }
                    current = ""
                    if result.count > 20 { break }  // Safety limit
                } else {
                    current += String(UnicodeScalar(buf[offset]))
                }
                offset += 1
            }
            return result.joined(separator: " ")
        }
        return args
    }

    private static func runLocalCommand(_ path: String, args: [String]) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    static func shellEsc(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellEscPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let relative = String(path.dropFirst(2))
            if relative.isEmpty { return "~/" }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return "~/" + components.map(shellEsc).joined(separator: "/")
        }
        return shellEsc(path)
    }
}
