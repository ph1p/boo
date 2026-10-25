import Foundation

/// Copies files between this Mac and a remote session by streaming a tar archive through
/// the same channel the explorer lists over (ssh control socket, `docker exec -i`, …).
///
/// tar instead of scp/`docker cp`: one code path for every session type, folders and
/// multiple items in a single round-trip, and nothing to install on the target beyond `tar`.
enum RemoteFileTransfer {
    struct Failure: Error {
        let message: String
    }

    /// Whether `session` can stream binary stdin/stdout. `adb shell` mangles line
    /// endings, and distrobox/toolbox `enter` allocate a tty.
    static func isSupported(_ session: RemoteSessionType) -> Bool {
        guard case .container(_, let tool) = session else { return true }
        switch tool {
        case .adb, .distrobox, .toolbox: return false
        default: return true
        }
    }

    /// A process that runs `script` remotely with stdin/stdout connected, not yet launched.
    static func remoteProcess(session: RemoteSessionType, script: String) -> Process? {
        let process = Process()
        let command = "sh -c \(shellEscape(script))"
        switch session {
        case .ssh(let host, let alias):
            guard !RemoteExplorer.disableRealSSH else { return nil }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteExplorer.sshArguments(host: alias ?? host, command: command)
        case .mosh(let host):
            guard !RemoteExplorer.disableRealSSH else { return nil }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteExplorer.sshArguments(host: host, command: command)
        case .container(let target, let tool):
            guard isSupported(session), let binary = RemoteExplorer.findBinary(tool.rawValue) else { return nil }
            process.executableURL = URL(fileURLWithPath: binary)
            switch tool {
            case .vagrant, .colima:
                process.arguments = RemoteExplorer.sshBasedToolArguments(target: target, tool: tool, command: script)
            case .kubectl, .oc:
                process.arguments = [tool.execSubcommand, "-i", target, "--", "sh", "-c", script]
            case .lxc:
                process.arguments = [tool.execSubcommand, target, "--", "sh", "-c", script]
            case .limactl:
                process.arguments = [tool.execSubcommand, target, "sh", "-c", script]
            default:
                process.arguments = [tool.execSubcommand, "-i", target, "sh", "-c", script]
            }
        }
        return process
    }

    // MARK: - Download

    /// Copy remote `paths` into local `destination`, each keeping its name (an existing
    /// item there is replaced). Runs on a background queue; completion on main.
    static func download(
        session: RemoteSessionType, paths: [String], to destination: String,
        completion: @escaping @MainActor @Sendable (Failure?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Failure?
            do {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                for (parent, names) in groupedByParent(paths) {
                    try stream(
                        remote: session, remoteScript: downloadScript(parent: parent, names: names),
                        local: ["-xf", "-", "-C", destination], remoteIsSource: true)
                }
            } catch let error as Failure {
                failure = error
            } catch {
                failure = Failure(message: error.localizedDescription)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    // MARK: - Upload

    /// Copy local `paths` into remote directory `destination`. Existing items are replaced.
    static func upload(
        session: RemoteSessionType, paths: [String], to destination: String,
        completion: @escaping @MainActor @Sendable (Failure?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Failure?
            do {
                for (parent, names) in groupedByParent(paths) {
                    // No AppleDouble `._` files, xattrs or ACLs: a Linux tar would either
                    // unpack them as junk files or warn about unknown pax headers.
                    let local = ["--no-xattrs", "--no-acls", "--no-fflags", "-cf", "-", "-C", parent] + names
                    try stream(
                        remote: session, remoteScript: uploadScript(destination: destination),
                        local: local, remoteIsSource: false)
                }
            } catch let error as Failure {
                failure = error
            } catch {
                failure = Failure(message: error.localizedDescription)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    // MARK: - Scripts

    /// `./name` so a leading `-` can't be read as a tar option.
    static func downloadScript(parent: String, names: [String]) -> String {
        let items = names.map { shellEscape("./" + $0) }.joined(separator: " ")
        return "cd \(RemoteExplorer.shellEscPath(parent)) && exec tar -cf - \(items)"
    }

    static func uploadScript(destination: String) -> String {
        "cd \(RemoteExplorer.shellEscPath(destination)) && exec tar -xf -"
    }

    /// Paths grouped by their parent directory, in first-seen order, so each group is
    /// one tar stream.
    static func groupedByParent(_ paths: [String]) -> [(parent: String, names: [String])] {
        var groups: [(parent: String, names: [String])] = []
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.parent == parent }) {
                groups[index].names.append(name)
            } else {
                groups.append((parent.isEmpty ? "/" : parent, [name]))
            }
        }
        return groups
    }

    // MARK: - Plumbing

    /// Pipe a remote process into a local `/usr/bin/tar` (or the other way round) and wait
    /// for both. Throws with the failing side's stderr.
    private static func stream(
        remote session: RemoteSessionType, remoteScript: String, local localArgs: [String], remoteIsSource: Bool
    ) throws {
        guard let remote = remoteProcess(session: session, script: remoteScript) else {
            throw Failure(message: "File transfer isn't supported for this session")
        }
        let local = Process()
        local.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        local.arguments = localArgs
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        local.environment = env

        let data = Pipe()
        let remoteErr = Pipe()
        let localErr = Pipe()
        remote.standardError = remoteErr
        local.standardError = localErr
        if remoteIsSource {
            remote.standardInput = FileHandle.nullDevice
            remote.standardOutput = data
            local.standardInput = data
            local.standardOutput = FileHandle.nullDevice
        } else {
            local.standardInput = FileHandle.nullDevice
            local.standardOutput = data
            remote.standardInput = data
            remote.standardOutput = FileHandle.nullDevice
        }

        let remoteErrText = StderrBuffer(remoteErr)
        let localErrText = StderrBuffer(localErr)
        do {
            try remote.run()
            try local.run()
        } catch {
            if remote.isRunning { remote.terminate() }
            throw Failure(message: error.localizedDescription)
        }
        // Our copies of the pipe ends must close, or the reader never sees EOF.
        try? data.fileHandleForReading.close()
        try? data.fileHandleForWriting.close()
        remote.waitUntilExit()
        local.waitUntilExit()

        if remote.terminationStatus != 0 {
            throw Failure(message: remoteErrText.text().nonEmpty ?? "Remote tar exited \(remote.terminationStatus)")
        }
        if local.terminationStatus != 0 {
            throw Failure(message: localErrText.text().nonEmpty ?? "tar exited \(local.terminationStatus)")
        }
    }

    /// Drains a stderr pipe while the process runs (a full pipe would stall it).
    private final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        init(_ pipe: Pipe) {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                    return
                }
                guard let self else { return }
                self.lock.lock()
                if self.data.count < 8192 { self.data.append(chunk) }
                self.lock.unlock()
            }
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            let raw = String(data: data, encoding: .utf8) ?? ""
            return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
