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
    private static func findChildProcess(parentPID: pid_t, name: String) -> pid_t? {
        let output = runLocalCommand("/usr/bin/pgrep", args: ["-P", "\(parentPID)", name])
        guard let line = output?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first,
              let pid = Int32(line) else { return nil }
        return pid
    }

    /// Extract SSH host from the process command line.
    private static func parseSSHHost(pid: pid_t) -> String? {
        guard let cmdline = runLocalCommand("/bin/ps", args: ["-o", "args=", "-p", "\(pid)"]) else { return nil }

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
        guard let cmdline = runLocalCommand("/bin/ps", args: ["-o", "args=", "-p", "\(pid)"]) else { return nil }

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
    private static func findControlSocket(host: String) -> String? {
        let sshDir = NSHomeDirectory() + "/.ssh"
        let fm = FileManager.default

        // Common ControlPath patterns: %h-%p-%r, %r@%h:%p, host-22, etc.
        guard let files = try? fm.contentsOfDirectory(atPath: sshDir) else { return nil }

        for file in files {
            // Socket files used by ControlMaster typically contain the host
            let lower = file.lowercased()
            let hostLower = host.lowercased()
            guard lower.contains(hostLower) else { continue }

            let path = sshDir + "/" + file
            var statBuf = stat()
            guard stat(path, &statBuf) == 0 else { continue }
            // Check if it's a socket (S_IFSOCK)
            if (statBuf.st_mode & S_IFMT) == S_IFSOCK {
                return path
            }
        }
        return nil
    }

    private static func runRemoteCommand(session: RemoteSessionType, command: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            switch session {
            case .ssh(let host):
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                var args = [
                    "-o", "ConnectTimeout=2",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "BatchMode=yes",
                ]
                // Try to reuse an existing ControlMaster socket so we don't need
                // key-based auth — the user's interactive session already authenticated.
                if let socket = findControlSocket(host: host) {
                    args += ["-o", "ControlPath=\(socket)"]
                }
                args += [host, command]
                process.arguments = args

            case .docker(let container):
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
                for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
                    if FileManager.default.fileExists(atPath: path) {
                        process.executableURL = URL(fileURLWithPath: path)
                        break
                    }
                }
                process.arguments = ["exec", container, "sh", "-c", command]
            }

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
