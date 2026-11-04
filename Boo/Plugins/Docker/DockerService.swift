import Combine
import Foundation

/// Manages Docker container discovery and lifecycle via the Docker Engine API
/// over the Unix domain socket (`docker.sock`).
final class DockerService: ObservableObject, @unchecked Sendable {
    static let shared = DockerService()

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        let status: String
        let state: ContainerState
        let ports: String
        /// Unix timestamp when the container was created, for uptime display.
        let createdAt: Date?
        /// Compose labels, when started by `docker compose`.
        var composeProject: String? = nil
        var composeService: String? = nil
        var composeWorkingDir: String? = nil
        var composeConfigFiles: [String] = []

        enum ContainerState: String {
            case running
            case exited
            case paused
            case created
            case restarting
            case dead
            case removing
            case unknown
        }
    }

    struct DockerImage: Identifiable, Equatable {
        let id: String
        let repoTag: String
        let size: Int64
        let createdAt: Date?
    }

    struct DockerNetwork: Identifiable, Equatable {
        let id: String
        let name: String
        let driver: String
        let scope: String
    }

    struct DockerVolume: Identifiable, Equatable {
        let name: String
        var id: String { name }
        let driver: String
        let mountpoint: String
    }

    private(set) var isAvailable = false
    /// Path to the Docker Unix socket.
    private(set) var socketPath: String?
    /// Path to the Docker CLI binary, used for `execCommand` terminal paste.
    private(set) var dockerPath: String?
    /// Human-readable connection error when the socket can't be found.
    @Published private(set) var connectionError: String?

    /// Container-change callbacks keyed by owner; one Docker plugin per window.
    private var containerObservers: [ObjectIdentifier: ([Container]) -> Void] = [:]
    /// Owners that asked for the event stream; it runs while any remain.
    private var watchers: Set<ObjectIdentifier> = []
    var watcherCount: Int { watchers.count }
    @Published private(set) var containers: [Container] = []
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var networks: [DockerNetwork] = []
    @Published private(set) var volumes: [DockerVolume] = []

    /// Well-known socket locations, checked in order.
    private static let socketSearchPaths: [String] = {
        var paths: [String] = []
        // DOCKER_HOST env var takes priority
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"],
            host.hasPrefix("unix://")
        {
            paths.append(String(host.dropFirst("unix://".count)))
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.append("\(home)/.colima/default/docker.sock")
            paths.append("\(home)/.colima/docker.sock")
            paths.append("\(home)/.docker/run/docker.sock")
        }
        paths.append("/var/run/docker.sock")
        return paths
    }()

    private init() {
        detectDocker()
    }

    /// Find the Docker socket. If `explicitPath` is non-empty, use it
    /// instead of auto-detecting.
    func detectDocker(explicitPath: String? = nil) {
        let override = explicitPath.flatMap { $0.isEmpty ? nil : $0 }

        if let path = override {
            if FileManager.default.fileExists(atPath: path) {
                socketPath = path
                isAvailable = true
                connectionError = nil
            } else {
                socketPath = nil
                isAvailable = false
                connectionError = "Socket not found at \(path)"
            }
        } else {
            // Auto-detect
            socketPath = nil
            for path in Self.socketSearchPaths {
                if FileManager.default.fileExists(atPath: path) {
                    socketPath = path
                    isAvailable = true
                    connectionError = nil
                    break
                }
            }
            if socketPath == nil {
                isAvailable = false
                connectionError = "No Docker socket found"
            }
        }

        // Verify the socket is actually reachable by pinging the daemon
        if isAvailable, let sock = socketPath {
            if Self.socketRequest(socketPath: sock, method: "GET", path: "/_ping", timeout: 3) == nil {
                isAvailable = false
                connectionError = "Docker socket found but daemon is not responding"
            }
        }

        // Detect CLI path for execCommand (terminal paste)
        dockerPath = nil
        for bin in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.fileExists(atPath: bin) {
                dockerPath = bin
                break
            }
        }
    }

    // MARK: - Socket HTTP Client

    /// File descriptor for the event stream connection. -1 when not streaming.
    private var eventFD: Int32 = -1
    private var eventSource: DispatchSourceRead?
    private let refreshDebounce = Debouncer(delay: 0.3)

    /// Connect a Unix domain socket to the given path.
    /// Returns the fd on success, -1 on failure. Caller owns the fd.
    private static func connectSocket(to path: String) -> Int32 {
        guard let fd = UnixSocket.connect(path: path) else { return -1 }

        // Don't let writes to a half-open socket raise SIGPIPE and kill the process
        // (e.g. a dangling docker.sock on a host with no running daemon).
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        return fd
    }

    /// Perform a synchronous HTTP request over the Docker Unix socket.
    /// Returns the response body on success, nil on failure.
    private static func socketRequest(
        socketPath: String,
        method: String,
        path: String,
        timeout: TimeInterval = 10
    ) -> Data? {
        let fd = connectSocket(to: socketPath)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request =
            "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { Darwin.send(fd, $0, request.utf8.count, 0) }
        guard sent == request.utf8.count else { return nil }

        // Read full response
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(buf, count: n)
        }

        // Split headers from body
        guard let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        // Check for chunked transfer encoding
        let headerRange = responseData.startIndex..<headerEnd.lowerBound
        let headerStr =
            String(data: responseData[headerRange], encoding: .utf8) ?? ""
        let body = responseData[headerEnd.upperBound...]

        if headerStr.lowercased().contains("transfer-encoding: chunked") {
            return decodeChunked(body)
        }
        return Data(body)
    }

    /// Decode HTTP chunked transfer encoding.
    private static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        var remaining = data
        while !remaining.isEmpty {
            // Find chunk size line
            guard let lineEnd = remaining.range(of: Data("\r\n".utf8)) else {
                break
            }
            let sizeRange = remaining.startIndex..<lineEnd.lowerBound
            let sizeStr =
                String(data: remaining[sizeRange], encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = UInt(sizeStr, radix: 16), chunkSize > 0 else {
                break
            }
            remaining = remaining[lineEnd.upperBound...]
            let off = Int(chunkSize)
            let end =
                remaining.index(
                    remaining.startIndex,
                    offsetBy: off,
                    limitedBy: remaining.endIndex
                ) ?? remaining.endIndex
            result.append(remaining[remaining.startIndex..<end])
            remaining = remaining[end...]
            // Skip trailing \r\n after chunk data
            if remaining.starts(with: Data("\r\n".utf8)) {
                let skip = remaining.index(remaining.startIndex, offsetBy: 2)
                remaining = remaining[skip...]
            }
        }
        return result
    }

    // MARK: - Event Stream

    /// Start watching Docker events via the socket event stream + initial refresh.
    func addContainersObserver(_ owner: AnyObject, _ observer: @escaping ([Container]) -> Void) {
        containerObservers[ObjectIdentifier(owner)] = observer
    }

    func removeContainersObserver(_ owner: AnyObject) {
        containerObservers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Ref-counted per owner: the event stream starts with the first watcher
    /// and stops when the last one leaves.
    func startWatching(_ owner: AnyObject) {
        let isFirst = watchers.isEmpty
        watchers.insert(ObjectIdentifier(owner))
        guard isFirst, isAvailable else { return }
        refreshAll()
        startEventStream()
    }

    func stopWatching(_ owner: AnyObject) {
        guard watchers.remove(ObjectIdentifier(owner)) != nil, watchers.isEmpty else { return }
        stopEventStream()
    }

    /// Reconnects the event stream after the socket path changed.
    func restartWatching() {
        stopEventStream()
        guard !watchers.isEmpty, isAvailable else { return }
        refreshAll()
        startEventStream()
    }

    private func stopEventStream() {
        refreshDebounce.cancel()
        // The source's cancel handler closes the fd; closing it here too could
        // close an unrelated descriptor that reused the number meanwhile.
        eventSource?.cancel()
        eventSource = nil
        eventFD = -1
    }

    /// Stream events from GET /events over the socket.
    private func startEventStream() {
        guard let sock = socketPath else { return }
        stopEventStream()

        let fd = Self.connectSocket(to: sock)
        guard fd >= 0 else { return }

        // Listen for container, image, network, and volume events
        let filters = #"{"type":["container","image","network","volume"]}"#
        let encoded =
            filters.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? filters
        let request =
            "GET /v1.43/events?filters=\(encoded) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let sent = request.withCString { Darwin.send(fd, $0, request.utf8.count, 0) }
        guard sent == request.utf8.count else {
            close(fd)
            return
        }

        eventFD = fd

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 {
                source.cancel()
                DispatchQueue.main.async { [weak self] in
                    // A restart may already have replaced this stream.
                    guard let self, self.eventSource === source else { return }
                    self.eventFD = -1
                    self.eventSource = nil
                    self.refreshAll()
                }
                return
            }
            // Debounce rapid events (e.g. docker-compose up)
            DispatchQueue.main.async { [weak self] in
                self?.debouncedRefreshAll()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        eventSource = source
    }

    private func debouncedRefreshAll() {
        refreshDebounce.schedule { [weak self] in
            self?.refreshAll()
        }
    }

    // MARK: - Refresh All

    func refreshAll() {
        refresh()
        refreshImages()
        refreshNetworks()
        refreshVolumes()
    }

    // MARK: - Container List

    /// Refresh container list via GET /containers/json?all=true.
    func refresh() {
        guard let sock = socketPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.socketRequest(
                socketPath: sock,
                method: "GET",
                path: "/v1.43/containers/json?all=true")
            let newContainers = Self.parseContainersJSON(data)
            DispatchQueue.main.async {
                guard let self else { return }
                if newContainers != self.containers {
                    self.containers = newContainers
                    for observer in self.containerObservers.values { observer(newContainers) }
                }
            }
        }
    }

    // MARK: - Images

    func refreshImages() {
        guard let sock = socketPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.socketRequest(
                socketPath: sock, method: "GET", path: "/v1.43/images/json")
            let newImages = Self.parseImagesJSON(data)
            DispatchQueue.main.async {
                guard let self else { return }
                if newImages != self.images { self.images = newImages }
            }
        }
    }

    func removeImage(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/images/\(id)", method: "DELETE", completion: completion)
    }

    // MARK: - Networks

    func refreshNetworks() {
        guard let sock = socketPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.socketRequest(
                socketPath: sock, method: "GET", path: "/v1.43/networks")
            let newNetworks = Self.parseNetworksJSON(data)
            DispatchQueue.main.async {
                guard let self else { return }
                if newNetworks != self.networks { self.networks = newNetworks }
            }
        }
    }

    func removeNetwork(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/networks/\(id)", method: "DELETE", completion: completion)
    }

    // MARK: - Volumes

    func refreshVolumes() {
        guard let sock = socketPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.socketRequest(
                socketPath: sock, method: "GET", path: "/v1.43/volumes")
            let newVolumes = Self.parseVolumesJSON(data)
            DispatchQueue.main.async {
                guard let self else { return }
                if newVolumes != self.volumes { self.volumes = newVolumes }
            }
        }
    }

    func removeVolume(_ name: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/volumes/\(name)", method: "DELETE", completion: completion)
    }

    // MARK: - Container Lifecycle

    /// Start a container.
    func startContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/start", completion: completion)
    }

    /// Stop a container.
    func stopContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/stop", completion: completion)
    }

    /// Restart a container.
    func restartContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)/restart", completion: completion)
    }

    /// Pause a running container.
    func pauseContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/pause", completion: completion)
    }

    /// Unpause a paused container.
    func unpauseContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)/unpause", completion: completion)
    }

    /// Remove a stopped container.
    func removeContainer(_ id: String, completion: (@Sendable () -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)", method: "DELETE",
            completion: completion)
    }

    /// Runs `docker compose … <action>` in the background; `completion`
    /// gets nil on success or the error text.
    @MainActor func composeAction(
        _ action: ComposeProject.Action, project: ComposeProject,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let docker = dockerPath else {
            completion("docker CLI not found")
            return
        }
        let args = project.arguments(action)
        let cwd = project.workingDir.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: docker)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            // `up` may pull images.
            let result = Subprocess.capture(process, timeout: action == .up ? 600 : 120)
            let error: String? =
                switch result {
                case nil: "docker compose \(action.rawValue) timed out"
                case let r? where r.status != 0:
                    r.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
                default: nil
                }
            DispatchQueue.main.async {
                self?.refreshAll()
                MainActor.assumeIsolated { completion(error) }
            }
        }
    }

    /// Exec into a container — returns the command string to paste into terminal.
    func execCommand(for container: Container) -> String {
        "docker exec -it \(shellEscape(container.name)) sh\r"
    }

    // MARK: - Private

    private func postAction(
        _ path: String, method: String = "POST",
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let sock = socketPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = Self.socketRequest(
                socketPath: sock, method: method, path: path)
            DispatchQueue.main.async {
                self?.refreshAll()
                completion?()
            }
        }
    }
}
