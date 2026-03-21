import Combine
import Foundation

/// Manages Docker container discovery and lifecycle.
final class DockerService: ObservableObject {
    static let shared = DockerService()

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        let status: String
        let state: ContainerState
        let ports: String

        enum ContainerState: String {
            case running
            case exited
            case paused
            case created
            case restarting
            case dead
            case unknown
        }
    }

    private(set) var isAvailable = false
    private(set) var dockerPath: String?
    private var pollTimer: Timer?

    var onContainersChanged: (([Container]) -> Void)?
    @Published private(set) var containers: [Container] = []

    private init() {
        detectDocker()
    }

    /// Check if Docker CLI is installed.
    func detectDocker() {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.fileExists(atPath: path) {
                dockerPath = path
                isAvailable = true
                return
            }
        }
        isAvailable = false
    }

    private var eventProcess: Process?

    /// Start watching Docker events via socket + initial refresh.
    func startWatching() {
        guard isAvailable else { return }
        pollTimer?.invalidate()
        refresh()
        startEventStream()
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        eventProcess?.terminate()
        eventProcess = nil
    }

    /// Watch `docker events` for container changes and refresh on each event.
    private func startEventStream() {
        guard let docker = dockerPath else { return }
        eventProcess?.terminate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["events", "--filter", "type=container", "--format", "{{.Status}}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — Docker daemon may have restarted. Fall back to polling.
                handle.readabilityHandler = nil
                DispatchQueue.main.async { [weak self] in
                    self?.eventProcess = nil
                    self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                        self?.refresh()
                    }
                }
                return
            }
            // Docker event received — refresh container list
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }

        do {
            try process.run()
            eventProcess = process
        } catch {
            // Fallback to polling if events don't work
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    // Keep old API for backwards compat
    func startPolling(interval: TimeInterval = 3.0) { startWatching() }
    func stopPolling() { stopWatching() }

    /// Refresh container list.
    func refresh() {
        guard let docker = dockerPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = Self.run(
                docker,
                args: [
                    "ps", "-a", "--format", "{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}"
                ])
            let newContainers = Self.parseContainers(output)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if newContainers != self.containers {
                    self.containers = newContainers
                    self.onContainersChanged?(newContainers)
                }
            }
        }
    }

    /// Start a container.
    func startContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["start", id], completion: completion)
    }

    /// Stop a container.
    func stopContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["stop", id], completion: completion)
    }

    /// Restart a container.
    func restartContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["restart", id], completion: completion)
    }

    /// Pause a running container.
    func pauseContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["pause", id], completion: completion)
    }

    /// Unpause a paused container.
    func unpauseContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["unpause", id], completion: completion)
    }

    /// Remove a stopped container.
    func removeContainer(_ id: String, completion: (() -> Void)? = nil) {
        runAsync(["rm", id], completion: completion)
    }

    /// Exec into a container — returns the command string to paste into terminal.
    func execCommand(for container: Container) -> String {
        "docker exec -it \(shellEscape(container.name)) sh\r"
    }

    // MARK: - Remote Docker

    /// List containers on a remote host via SSH.
    static func remoteContainers(host: String, completion: @escaping ([Container]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let output = run(
                "/usr/bin/ssh",
                args: [
                    "-o", "ConnectTimeout=3",
                    "-o", "BatchMode=yes",
                    host,
                    "docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}'"
                ])
            let containers = parseContainers(output)
            DispatchQueue.main.async { completion(containers) }
        }
    }

    /// Run a Docker command on a remote host.
    static func remoteDockerCommand(host: String, args: [String], completion: (() -> Void)? = nil) {
        let cmd = "docker " + args.joined(separator: " ")
        DispatchQueue.global(qos: .utility).async {
            _ = run(
                "/usr/bin/ssh",
                args: [
                    "-o", "ConnectTimeout=3",
                    "-o", "BatchMode=yes",
                    host, cmd
                ])
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - Private

    private func runAsync(_ args: [String], completion: (() -> Void)? = nil) {
        guard let docker = dockerPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = Self.run(docker, args: args)
            DispatchQueue.main.async {
                self?.refresh()
                completion?()
            }
        }
    }

    private static func run(_ executable: String, args: [String]) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    private static func parseContainers(_ output: String?) -> [Container] {
        guard let output = output, !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 5).map(String.init)
            guard parts.count >= 5 else { return nil }
            let stateStr = parts[4].lowercased()
            let state: Container.ContainerState = Container.ContainerState(rawValue: stateStr) ?? .unknown
            return Container(
                id: String(parts[0].prefix(12)),
                name: parts[1],
                image: parts[2],
                status: parts[3],
                state: state,
                ports: parts.count > 5 ? parts[5] : ""
            )
        }
    }
}
