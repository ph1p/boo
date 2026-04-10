import Combine
import Foundation

/// Manages Docker container discovery and lifecycle via the Docker Engine API
/// over the Unix domain socket (`docker.sock`).
final class DockerService: ObservableObject {
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

    var onContainersChanged: (([Container]) -> Void)?
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
    private var refreshDebounce: DispatchWorkItem?

    /// Connect a Unix domain socket to the given path.
    /// Returns the fd on success, -1 on failure. Caller owns the fd.
    private static func connectSocket(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
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
    func startWatching() {
        guard isAvailable else { return }
        refreshAll()
        startEventStream()
    }

    func stopWatching() {
        stopEventStream()
    }

    private func stopEventStream() {
        refreshDebounce?.cancel()
        refreshDebounce = nil
        eventSource?.cancel()
        eventSource = nil
        if eventFD >= 0 {
            close(eventFD)
            eventFD = -1
        }
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
                    self?.eventFD = -1
                    self?.eventSource = nil
                    self?.refreshAll()
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
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshAll()
        }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
                guard let self = self else { return }
                if newContainers != self.containers {
                    self.containers = newContainers
                    self.onContainersChanged?(newContainers)
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
                guard let self = self else { return }
                if newImages != self.images { self.images = newImages }
            }
        }
    }

    func removeImage(_ id: String, completion: (() -> Void)? = nil) {
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
                guard let self = self else { return }
                if newNetworks != self.networks { self.networks = newNetworks }
            }
        }
    }

    func removeNetwork(_ id: String, completion: (() -> Void)? = nil) {
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
                guard let self = self else { return }
                if newVolumes != self.volumes { self.volumes = newVolumes }
            }
        }
    }

    func removeVolume(_ name: String, completion: (() -> Void)? = nil) {
        postAction("/v1.43/volumes/\(name)", method: "DELETE", completion: completion)
    }

    // MARK: - Container Lifecycle

    /// Start a container.
    func startContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/start", completion: completion)
    }

    /// Stop a container.
    func stopContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/stop", completion: completion)
    }

    /// Restart a container.
    func restartContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)/restart", completion: completion)
    }

    /// Pause a running container.
    func pauseContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction("/v1.43/containers/\(id)/pause", completion: completion)
    }

    /// Unpause a paused container.
    func unpauseContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)/unpause", completion: completion)
    }

    /// Remove a stopped container.
    func removeContainer(_ id: String, completion: (() -> Void)? = nil) {
        postAction(
            "/v1.43/containers/\(id)", method: "DELETE",
            completion: completion)
    }

    /// Exec into a container — returns the command string to paste into terminal.
    func execCommand(for container: Container) -> String {
        "docker exec -it \(shellEscape(container.name)) sh\r"
    }

    // MARK: - Remote Docker

    /// List containers on a remote host via SSH.
    static func remoteContainers(
        host: String, completion: @escaping ([Container]) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let fmt =
                "{{.ID}}\\t{{.Names}}\\t{{.Image}}"
                + "\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}"
            let output = runProcess(
                "/usr/bin/ssh",
                args: [
                    "-o", "ConnectTimeout=3",
                    "-o", "BatchMode=yes",
                    host,
                    "docker ps -a --format '\(fmt)'"
                ])
            let containers = parseCLIContainers(output)
            DispatchQueue.main.async { completion(containers) }
        }
    }

    /// Run a Docker command on a remote host.
    static func remoteDockerCommand(
        host: String, args: [String], completion: (() -> Void)? = nil
    ) {
        let cmd = "docker " + args.joined(separator: " ")
        DispatchQueue.global(qos: .utility).async {
            _ = runProcess(
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

    private func postAction(
        _ path: String, method: String = "POST",
        completion: (() -> Void)? = nil
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

    // MARK: - JSON Parsing (socket API)

    private static func parseContainersJSON(_ data: Data?) -> [Container] {
        guard let data = data else { return [] }
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String,
                let names = obj["Names"] as? [String],
                let image = obj["Image"] as? String,
                let status = obj["Status"] as? String,
                let stateStr = obj["State"] as? String
            else { return nil }

            let name =
                names.first?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")) ?? id
            let state =
                Container.ContainerState(rawValue: stateStr.lowercased())
                ?? .unknown
            let ports = formatPorts(obj["Ports"])
            let createdAt: Date?
            if let createdEpoch = obj["Created"] as? TimeInterval {
                createdAt = Date(timeIntervalSince1970: createdEpoch)
            } else {
                createdAt = nil
            }

            return Container(
                id: String(id.prefix(12)),
                name: name,
                image: image,
                status: status,
                state: state,
                ports: ports,
                createdAt: createdAt
            )
        }
    }

    private static func parseImagesJSON(_ data: Data?) -> [DockerImage] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String else { return nil }
            let shortID = id.hasPrefix("sha256:") ? String(id.dropFirst(7).prefix(12)) : String(id.prefix(12))
            let tags = obj["RepoTags"] as? [String] ?? []
            let repoTag = tags.first(where: { !$0.contains("<none>") }) ?? tags.first ?? "<none>"
            let size = obj["Size"] as? Int64 ?? 0
            let createdAt: Date?
            if let epoch = obj["Created"] as? TimeInterval {
                createdAt = Date(timeIntervalSince1970: epoch)
            } else {
                createdAt = nil
            }
            return DockerImage(id: shortID, repoTag: repoTag, size: size, createdAt: createdAt)
        }
    }

    private static func parseNetworksJSON(_ data: Data?) -> [DockerNetwork] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String,
                let name = obj["Name"] as? String
            else { return nil }
            let driver = obj["Driver"] as? String ?? ""
            let scope = obj["Scope"] as? String ?? ""
            return DockerNetwork(
                id: String(id.prefix(12)), name: name, driver: driver, scope: scope)
        }
        .filter { !["bridge", "host", "none"].contains($0.name) }
    }

    private static func parseVolumesJSON(_ data: Data?) -> [DockerVolume] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let volumes = json["Volumes"] as? [[String: Any]]
        else { return [] }
        return volumes.compactMap { obj in
            guard let name = obj["Name"] as? String else { return nil }
            let driver = obj["Driver"] as? String ?? ""
            let mountpoint = obj["Mountpoint"] as? String ?? ""
            return DockerVolume(name: name, driver: driver, mountpoint: mountpoint)
        }
    }

    /// Format the Ports array from the Docker API into a display string.
    private static func formatPorts(_ portsObj: Any?) -> String {
        guard let portsArray = portsObj as? [[String: Any]] else {
            return ""
        }
        var parts: [String] = []
        for port in portsArray {
            let privatePort = port["PrivatePort"] as? Int ?? 0
            let portType = port["Type"] as? String ?? "tcp"
            if let publicPort = port["PublicPort"] as? Int,
                publicPort > 0
            {
                let ip = port["IP"] as? String ?? ""
                if ip == "::" { continue }  // Skip IPv6 duplicates
                if ip.isEmpty || ip == "0.0.0.0" {
                    parts.append(
                        "\(publicPort)->\(privatePort)/\(portType)")
                } else {
                    parts.append(
                        "\(ip):\(publicPort)->\(privatePort)/\(portType)"
                    )
                }
            } else {
                parts.append("\(privatePort)/\(portType)")
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - CLI Process (for remote only)

    private static func runProcess(
        _ executable: String, args: [String]
    ) -> String? {
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

    /// Parse CLI tab-separated output (used for remote containers via SSH).
    private static func parseCLIContainers(
        _ output: String?
    ) -> [Container] {
        guard let output = output, !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 5)
                .map(String.init)
            guard parts.count >= 5 else { return nil }
            let stateStr = parts[4].lowercased()
            let state =
                Container.ContainerState(rawValue: stateStr) ?? .unknown
            return Container(
                id: String(parts[0].prefix(12)),
                name: parts[1],
                image: parts[2],
                status: parts[3],
                state: state,
                ports: parts.count > 5 ? parts[5] : "",
                createdAt: nil
            )
        }
    }
}
