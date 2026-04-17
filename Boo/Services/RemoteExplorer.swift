import Darwin
import Foundation

/// Detects remote sessions (SSH, Mosh, Docker, kubectl, etc.) and provides file listing.
final class RemoteExplorer {
    /// When true, `runSSH` returns nil immediately instead of spawning `/usr/bin/ssh`.
    /// Automatically enabled when running under XCTest to avoid real network calls.
    static var disableRealSSH: Bool = {
        NSClassFromString("XCTestCase") != nil
    }()

    struct RemoteEntry {
        let name: String
        let isDirectory: Bool
    }

    // MARK: - Detection

    /// Detect if the shell has a remote child process.
    static func detectRemoteSession(shellPID: pid_t) -> RemoteSessionType? {
        if let host = detectSSH(shellPID: shellPID) {
            return .ssh(host: host)
        }
        if let host = detectMosh(shellPID: shellPID) {
            return .mosh(host: host)
        }
        if let result = detectContainer(shellPID: shellPID) {
            return result
        }
        return nil
    }

    private static func detectSSH(shellPID: pid_t) -> String? {
        guard let pid = findChildProcess(parentPID: shellPID, name: "ssh") else { return nil }
        guard let host = parseSSHHost(pid: pid), !isGitForgeHost(host) else { return nil }
        return host
    }

    /// Whether a host is a known git forge (non-interactive SSH like git push/pull).
    private static func isGitForgeHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        // Strip "user@" prefix if present (e.g. "git@github.com" → "github.com")
        let hostname: String
        if let atIdx = lower.firstIndex(of: "@") {
            hostname = String(lower[lower.index(after: atIdx)...])
        } else {
            hostname = lower
        }
        let forgeHosts: Set<String> = [
            "github.com", "gitlab.com", "bitbucket.org", "codeberg.org",
            "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
            "source.developers.google.com", "ssh.gitlab.gnome.org", "sr.ht"
        ]
        return forgeHosts.contains(hostname)
    }

    private static func detectMosh(shellPID: pid_t) -> String? {
        // mosh-client is the local process name
        let pid =
            findChildProcess(parentPID: shellPID, name: "mosh-client")
            ?? findChildProcess(parentPID: shellPID, name: "mosh")
        guard let pid else { return nil }
        return parseMoshHost(pid: pid)
    }

    /// Detect any container/VM tool child process.
    private static func detectContainer(shellPID: pid_t) -> RemoteSessionType? {
        for tool in ContainerTool.all {
            for processName in tool.processNames {
                if let pid = findChildProcess(parentPID: shellPID, name: processName) {
                    if let target = parseContainerTarget(pid: pid, tool: tool) {
                        return .container(target: target, tool: tool)
                    }
                }
            }
        }
        return nil
    }

    /// Find a child process by name using pgrep.
    /// Find child process by name using proc_listchildpids + proc_name.
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
                let base = exe.lastPathComponent
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

    /// Extract the target (container name, pod name, VM name, etc.) from a container tool command line.
    /// Returns nil if the command is not an interactive shell session (e.g. `docker logs`).
    private static func parseContainerTarget(pid: pid_t, tool: ContainerTool) -> String? {
        guard let cmdline = getProcessArgs(pid: pid) else { return nil }
        let args = cmdline.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        remoteLog("[RemoteExplorer] parseContainerTarget: tool=\(tool.rawValue) args=\(args.joined(separator: " "))")
        let target = tool.interactiveTarget(from: args)
        if target == nil {
            remoteLog("[RemoteExplorer] parseContainerTarget: rejected \(tool.rawValue) command")
        }
        return target
    }

    /// Extract host from mosh command line: `mosh [options] host`
    private static func parseMoshHost(pid: pid_t) -> String? {
        guard let cmdline = getProcessArgs(pid: pid) else { return nil }
        let args = cmdline.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        var skipNext = false

        let valueOpts: Set<String> = [
            "-p", "--port", "--ssh", "--predict", "--predict-overwrite"
        ]

        for (i, arg) in args.enumerated() {
            if i == 0 { continue }
            if skipNext {
                skipNext = false
                continue
            }
            if arg.hasPrefix("-") {
                if valueOpts.contains(arg) { skipNext = true }
                continue
            }
            // First non-option is the host
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

    /// Get the process name for a PID, stripping the login-shell "-" prefix.
    static func processName(pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    /// Walk from a process down single-child chains to find the actual shell.
    /// Ghostty forks: Boo → login → shell. This walks login → shell.
    /// Stops when: the process has 0 children, >1 children, or is a known shell.
    static func walkToLeafShell(from pid: pid_t) -> pid_t {
        let shellNames = ProcessIcon.shells
        var current = pid
        for _ in 0..<5 {  // safety limit
            let cleanName = processName(pid: current)
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

    /// Resolve a container hostname (truncated container ID) to a container name.
    /// Tries docker, podman, and nerdctl. Returns nil if not a container ID.
    private static var containerHostnameCache: [String: (name: String?, expires: Date)] = [:]

    static func resolveDockerHostname(_ hostname: String) -> String? {
        resolveContainerHostname(hostname)
    }

    static func resolveContainerHostname(_ hostname: String) -> String? {
        // Container hostnames are typically 12-char hex prefixes
        let cleaned = hostname.lowercased()
        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }

        // Check cache
        if let cached = containerHostnameCache[cleaned], Date() < cached.expires {
            return cached.name
        }

        // Try docker, podman, nerdctl
        for toolName in ["docker", "podman", "nerdctl"] {
            guard let binary = findBinary(toolName) else { continue }
            let result = runLocalCommand(binary, args: ["ps", "--filter", "id=\(cleaned)", "--format", "{{.Names}}"])
            let name = result?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                containerHostnameCache[cleaned] = (name: name, expires: Date().addingTimeInterval(30))
                return name
            }
        }

        containerHostnameCache[cleaned] = (name: nil, expires: Date().addingTimeInterval(30))
        return nil
    }

    // MARK: - Detection (enhanced)

    /// Detect remote session with SSH tunnel filtering.
    static func detectRemoteSessionFiltered(shellPID: pid_t) -> RemoteSessionType? {
        remoteLog("[RemoteExplorer] detectRemoteSessionFiltered: shellPID=\(shellPID)")
        // Check SSH first
        if let sshPID = findChildProcess(parentPID: shellPID, name: "ssh") {
            if !isSSHTunnel(pid: sshPID) {
                if let host = parseSSHHost(pid: sshPID), !isGitForgeHost(host) {
                    return .ssh(host: host)
                }
            }
        }
        // Check Mosh
        if let host = detectMosh(shellPID: shellPID) {
            return .mosh(host: host)
        }
        // Check container/VM tools
        if let result = detectContainer(shellPID: shellPID) {
            remoteLog("[RemoteExplorer] detected container: \(result)")
            return result
        }
        remoteLog("[RemoteExplorer] no remote session detected for shellPID=\(shellPID)")
        return nil
    }

    // MARK: - ControlMaster Setup

    /// Returns true if ControlMaster is already configured in ~/.ssh/config.
    static func hasControlMaster() -> Bool {
        let configPath = NSHomeDirectory() + "/.ssh/config"
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            return existing.lowercased().contains("controlmaster")
        }
        return false
    }

    /// Append ControlMaster config to ~/.ssh/config if not already present.
    /// Caller is responsible for gating this behind user consent.
    @discardableResult
    static func enableControlMaster() -> Bool {
        let configPath = NSHomeDirectory() + "/.ssh/config"
        let fm = FileManager.default

        if hasControlMaster() { return true }

        let sshDir = NSHomeDirectory() + "/.ssh"
        if !fm.fileExists(atPath: sshDir) {
            do {
                try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)
            } catch {
                debugLog("[SSH] Failed to create ~/.ssh: \(error)")
                return false
            }
        }

        let block =
            "\n# Added by Boo — enables SSH connection sharing for file explorer\nHost *\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-%r@%h:%p\n  ControlPersist 10m\n"

        if let handle = FileHandle(forWritingAtPath: configPath) {
            handle.seekToEndOfFile()
            if let data = block.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
            return true
        } else {
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
            remoteLog("[RemoteExplorer] resolveRemoteHome cache hit: key=\(key) home=\(cached)")
            completion(cached)
            return
        }
        remoteLog("[RemoteExplorer] resolveRemoteHome: running 'echo ~' for key=\(key)")
        // `echo ~` works on bash, zsh, sh, dash, fish, ash (busybox)
        runRemoteCommand(session: session, command: "echo ~") { output in
            let home = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteLog("[RemoteExplorer] resolveRemoteHome result: key=\(key) home=\(home ?? "nil")")
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

    /// Run a command on the remote target. Public API for plugins that need custom commands.
    static func runPublicRemoteCommand(
        session: RemoteSessionType, command: String, completion: @escaping (String?) -> Void
    ) {
        runRemoteCommand(session: session, command: command, completion: completion)
    }

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
        remoteLog(
            "[RemoteExplorer] listRemoteDirectory: session=\(session.envType):\(session.displayName) path=\(path) cmd=\(cmd)"
        )

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

        // Search common socket directories (never /tmp — world-writable, attacker-plantable)
        let home = NSHomeDirectory()
        let searchDirs = [
            home + "/.ssh",
            home + "/.ssh/sockets",
            home + "/.ssh/cm"
        ]

        let myUID = getuid()
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
                // Must be a socket AND owned by the current user
                guard (statBuf.st_mode & S_IFMT) == S_IFSOCK, statBuf.st_uid == myUID else {
                    continue
                }
                return path
            }
        }
        return nil
    }

    private static func runSSH(host: String, command: String, extraArgs: [String] = []) -> String? {
        if disableRealSSH { return nil }
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
        // Use Boo's managed socket if available (enables multiplexing without user config).
        // Fall back to finding any existing ControlMaster socket for the host (e.g. the
        // user's interactive SSH session). This enables file listing for direct IP connections
        // like `ssh root@157.90.31.161` where SSHControlManager can't create its own master.
        if let socket = SSHControlManager.shared.socketPath(for: host) {
            remoteLog("[RemoteExplorer] runSSH: using managed socket for \(host): \(socket)")
            args += ["-o", "ControlPath=\(socket)"]
        } else if let socket = findControlSocket(host: host) {
            remoteLog("[RemoteExplorer] runSSH: using found socket for \(host): \(socket)")
            args += ["-o", "ControlPath=\(socket)"]
        } else {
            remoteLog("[RemoteExplorer] runSSH: no socket found for \(host)")
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
                debugLog(
                    "[RemoteExplorer] SSH failed: host=\(host) exit=\(process.terminationStatus) stderr=\(stderr.prefix(200))"
                )
                return nil
            }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            debugLog("[RemoteExplorer] process.run() exception: \(error)")
            return nil
        }
    }

    private static func runRemoteCommand(
        session: RemoteSessionType, command: String, completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            remoteLog(
                "[RemoteExplorer] runRemoteCommand: type=\(session.envType) target=\(session.sshConnectionTarget) cmd=\(command.prefix(80))"
            )
            let result: String?
            switch session {
            case .ssh(let host, let alias):
                let target = alias ?? host
                result = runSSH(host: target, command: command)

            case .mosh(let host):
                // Mosh doesn't support command execution; use SSH to the same host
                result = runSSH(host: host, command: command)

            case .container(let target, let tool):
                if tool == .vagrant || tool == .colima {
                    // These tools connect via SSH under the hood
                    result = runContainerSSH(target: target, tool: tool, command: command)
                } else {
                    result = runContainerExec(target: target, tool: tool, command: command)
                }
            }
            remoteLog(
                "[RemoteExplorer] runRemoteCommand result: type=\(session.envType) hasOutput=\(result != nil) length=\(result?.count ?? 0)"
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Run a command inside a container/VM via `<tool> exec <target> sh -c <command>`.
    private static func runContainerExec(target: String, tool: ContainerTool, command: String) -> String? {
        guard let binary = findBinary(tool.rawValue) else {
            debugLog("[RemoteExplorer] \(tool.rawValue) binary not found")
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)

        // Build arguments based on tool
        var args: [String]
        switch tool {
        case .kubectl, .oc:
            // kubectl exec <pod> -- sh -c "command"
            args = [tool.execSubcommand, target, "--", "sh", "-c", command]
        case .lxc:
            // lxc exec <container> -- sh -c "command"
            args = [tool.execSubcommand, target, "--", "sh", "-c", command]
        case .distrobox, .toolbox:
            // distrobox enter <name> -- sh -c "command"
            args = [tool.execSubcommand, target, "--", "sh", "-c", command]
        case .limactl:
            // limactl shell <vm> sh -c "command"
            args = [tool.execSubcommand, target, "sh", "-c", command]
        case .adb:
            // adb shell sh -c "command"
            args = [tool.execSubcommand, "sh", "-c", command]
        default:
            // docker/podman/nerdctl exec <container> sh -c "command"
            args = [tool.execSubcommand, target, "sh", "-c", command]
        }

        remoteLog("[RemoteExplorer] runContainerExec: \(binary) \(args.joined(separator: " "))")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                remoteLog(
                    "[RemoteExplorer] \(tool.rawValue) exec FAILED: target=\(target) exit=\(process.terminationStatus) stderr=\(stderr.prefix(300))"
                )
                return nil
            }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            remoteLog("[RemoteExplorer] \(tool.rawValue) exec OK: target=\(target) outputLen=\(output?.count ?? 0)")
            return output
        } catch {
            debugLog("[RemoteExplorer] \(tool.rawValue) exec exception: \(error)")
            return nil
        }
    }

    /// Run a command on a VM via SSH-based tools (vagrant, colima).
    private static func runContainerSSH(target: String, tool: ContainerTool, command: String) -> String? {
        guard let binary = findBinary(tool.rawValue) else {
            debugLog("[RemoteExplorer] \(tool.rawValue) binary not found")
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = sshBasedToolArguments(target: target, tool: tool, command: command)

        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                debugLog(
                    "[RemoteExplorer] \(tool.rawValue) ssh failed: exit=\(process.terminationStatus) stderr=\(stderr.prefix(200))"
                )
                return nil
            }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            debugLog("[RemoteExplorer] \(tool.rawValue) ssh exception: \(error)")
            return nil
        }
    }

    static func sshBasedToolArguments(target: String, tool: ContainerTool, command: String) -> [String] {
        switch tool {
        case .vagrant:
            if target.isEmpty {
                return ["ssh", "-c", command]
            }
            return ["ssh", target, "-c", command]
        case .colima:
            if target.isEmpty {
                return ["ssh", "--", "sh", "-c", command]
            }
            return ["ssh", "--profile", target, "--", "sh", "-c", command]
        default:
            return [tool.execSubcommand, target, "sh", "-c", command]
        }
    }

    /// Find a binary in common paths.
    static func findBinary(_ name: String) -> String? {
        let searchPaths = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/bin/\(name)",
            "/snap/bin/\(name)"
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
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

    static func shellEscPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let relative = String(path.dropFirst(2))
            if relative.isEmpty { return "~/" }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return "~/" + components.map(shellEscape).joined(separator: "/")
        }
        return shellEscape(path)
    }
}
