import Foundation
import Darwin

/// The type of remote session detected.
enum RemoteSessionType: Equatable {
    case ssh(host: String)
    case docker(container: String)

    var displayName: String {
        switch self {
        case .ssh(let host): return host
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
        case .ssh: return "Waiting for SSH authentication.\nFile explorer requires key-based auth or ControlMaster."
        case .docker: return "Waiting for container shell to start."
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
    private static func findChildProcess(parentPID: pid_t, name: String) -> pid_t? {
        let count = proc_listchildpids(parentPID, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let actual = proc_listchildpids(parentPID, &pids, Int32(count) * Int32(MemoryLayout<pid_t>.size))
        guard actual > 0 else { return nil }
        let pidCount = Int(actual) / MemoryLayout<pid_t>.size

        for i in 0..<min(pidCount, pids.count) {
            let child = pids[i]
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
            proc_name(child, &nameBuffer, UInt32(nameBuffer.count))
            let procName = String(cString: nameBuffer)
            if procName.contains(name) { return child }
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
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                let valueOpts: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-w", "-E"]
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
            if skipNext { skipNext = false; continue }
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

        let block = "\n# Added by Exterm — enables SSH connection sharing for file explorer\nHost *\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-%r@%h:%p\n  ControlPersist 10m\n"

        if let handle = FileHandle(forWritingAtPath: configPath) {
            handle.seekToEndOfFile()
            if let data = block.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
            return true
        } else {
            // Config file doesn't exist yet — create it
            return fm.createFile(atPath: configPath, contents: block.data(using: .utf8),
                                 attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: - Remote Commands

    /// Get the remote working directory.
    static func getRemoteCwd(session: RemoteSessionType, completion: @escaping (String?) -> Void) {
        runRemoteCommand(session: session, command: "pwd") { output in
            completion(output?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// List directory contents on the remote target.
    static func listRemoteDirectory(session: RemoteSessionType, path: String, completion: @escaping ([RemoteEntry]) -> Void) {
        let cmd = "ls -1AF \(shellEsc(path)) 2>/dev/null"

        runRemoteCommand(session: session, command: cmd) { output in
            guard let output = output, !output.isEmpty else { completion([]); return }

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

    // MARK: - Command Execution

    /// Find an existing ControlMaster socket for the given host.
    /// `host` may be "hostname" or "user@hostname".
    private static func findControlSocket(host: String) -> String? {
        // Build search terms: both the full host string and just the hostname part
        var searchTerms: [String] = [host.lowercased()]
        if let atIdx = host.firstIndex(of: "@") {
            let hostname = String(host[host.index(after: atIdx)...]).lowercased()
            let user = String(host[..<atIdx]).lowercased()
            searchTerms.append(hostname)
            searchTerms.append(user)
        }

        // Search common socket directories
        let home = NSHomeDirectory()
        let searchDirs = [
            home + "/.ssh",
            home + "/.ssh/sockets",
            home + "/.ssh/cm",
            "/tmp",
        ]

        let fm = FileManager.default
        for dir in searchDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files {
                let lower = file.lowercased()
                // Socket must match at least the hostname
                guard searchTerms.contains(where: { lower.contains($0) }) else { continue }

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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-n",  // no stdin — prevents password prompts from blocking
            "-o", "ConnectTimeout=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
        ]
        args += extraArgs
        args += [host, command]
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runRemoteCommand(session: RemoteSessionType, command: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch session {
            case .ssh(let host):
                // Try with ControlMaster socket first (works with password-only auth)
                if let socket = findControlSocket(host: host) {
                    if let result = runSSH(host: host, command: command, extraArgs: ["-o", "ControlPath=\(socket)"]) {
                        DispatchQueue.main.async { completion(result) }
                        return
                    }
                }
                // Fall back to plain BatchMode (works with key-based auth / ssh-agent)
                let result = runSSH(host: host, command: command)
                DispatchQueue.main.async { completion(result) }

            case .docker(let container):
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
                for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
                    if FileManager.default.fileExists(atPath: path) {
                        process.executableURL = URL(fileURLWithPath: path)
                        break
                    }
                }
                process.arguments = ["exec", container, "sh", "-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    DispatchQueue.main.async { completion(String(data: data, encoding: .utf8)) }
                } catch {
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
                    if result.count > 20 { break } // Safety limit
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

    private static func shellEsc(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
