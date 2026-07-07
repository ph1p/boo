import Darwin
import Foundation
import Security

/// HTTP server exposing a web interface to control Boo remotely.
/// Serves an embedded single-page UI plus a JSON command API. Commands are
/// routed to MainActor handlers via `onCommand` (wired by MainWindowController).
///
/// Security: every API request must carry the session token (regenerated on
/// each start) via `Authorization: Bearer <token>` or `?token=<token>`.
/// Connections use `Connection: close` — the UI polls, no keep-alive needed.
///
/// Thread safety: all socket I/O happens on `queue`. Public accessors
/// snapshot state synchronously via `queue.sync`.
final class RemoteControlServer: @unchecked Sendable {
    static let shared = RemoteControlServer()

    /// Command handler — receives (cmd, json, reply). Reply may be called from
    /// any thread; the server serializes the response and closes the socket.
    var onCommand: ((_ cmd: String, _ json: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void)?

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "com.boo.remotecontrol", qos: .utility)

    private static let maxClients = 32
    private static let maxRequestBytes = 65536

    /// Commands accepted from the web API.
    private static let allowedCommands: Set<String> = [
        "get_state", "get_screen", "send_text", "send_key",
        "switch_workspace", "select_tab", "new_tab", "select_pane"
    ]

    private(set) var token: String = ""
    private(set) var port: UInt16 = 0

    var isRunning: Bool { queue.sync { serverFD >= 0 } }

    /// URL reachable from other devices on the LAN (falls back to localhost).
    var accessURL: String {
        let host = Self.lanIPAddress() ?? "127.0.0.1"
        return "http://\(host):\(port)/#\(token)"
    }

    private init() {}

    // MARK: - Lifecycle

    /// Start listening. Returns true on success (checked synchronously).
    @discardableResult
    func start(port requestedPort: UInt16) -> Bool {
        queue.sync {
            guard serverFD < 0 else { return true }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                booLog(.error, .socket, "RemoteControl: socket() failed: \(errno)")
                return false
            }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var flags = fcntl(fd, F_GETFL)
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = requestedPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                booLog(.error, .socket, "RemoteControl: bind :\(requestedPort) failed: \(errno)")
                close(fd)
                return false
            }
            guard listen(fd, 8) == 0 else {
                booLog(.error, .socket, "RemoteControl: listen failed: \(errno)")
                close(fd)
                return false
            }

            serverFD = fd
            port = requestedPort
            token = Self.generateToken()

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClient() }
            source.setCancelHandler { [weak self] in
                if let fd = self?.serverFD, fd >= 0 {
                    close(fd)
                    self?.serverFD = -1
                }
            }
            source.resume()
            acceptSource = source

            booLog(.info, .socket, "RemoteControl: listening on :\(requestedPort)")
            return true
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for source in clientSources.values {
                source.cancel()
            }
            clientSources.removeAll()
            clientBuffers.removeAll()
            if serverFD >= 0 {
                close(serverFD)
                serverFD = -1
            }
            token = ""
            booLog(.info, .socket, "RemoteControl: stopped")
        }
    }

    // MARK: - Accept / Read

    private func acceptClient() {
        guard clientSources.count < Self.maxClients else {
            // Drain and drop to avoid busy-looping the read source.
            let fd = accept(serverFD, nil, nil)
            if fd >= 0 { close(fd) }
            return
        }
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }

        var flags = fcntl(clientFD, F_GETFL)
        flags |= O_NONBLOCK
        _ = fcntl(clientFD, F_SETFL, flags)
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        clientBuffers[clientFD] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(fd: clientFD) }
        source.setCancelHandler { [weak self] in
            close(clientFD)
            self?.clientBuffers.removeValue(forKey: clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }
        source.resume()
        clientSources[clientFD] = source
    }

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        clientBuffers[fd]?.append(contentsOf: buf[0..<n])

        guard let buffer = clientBuffers[fd] else { return }
        if buffer.count > Self.maxRequestBytes {
            clientSources[fd]?.cancel()
            return
        }

        // Wait for full headers
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            clientSources[fd]?.cancel()
            return
        }

        let contentLength = Self.contentLength(fromHeaders: headerText)
        guard contentLength <= Self.maxRequestBytes else {
            clientSources[fd]?.cancel()
            return
        }
        let bodyStart = headerEnd.upperBound
        let bodyAvailable = buffer.endIndex - bodyStart
        guard bodyAvailable >= contentLength else { return }  // wait for body

        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        handleRequest(fd: fd, headerText: headerText, body: Data(body))
    }

    /// Case-insensitive lookup of a header value in raw header text.
    private static func headerValue(_ name: String, in headers: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func contentLength(fromHeaders headers: String) -> Int {
        headerValue("content-length", in: headers).flatMap(Int.init) ?? 0
    }

    // MARK: - Request Handling

    private func handleRequest(fd: Int32, headerText: String, body: Data) {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            sendError(fd: fd, status: "400 Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendError(fd: fd, status: "400 Bad Request")
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveIndex(fd: fd)
        case ("GET", "/ghostty-vt.wasm"):
            serveWasm(fd: fd)
        case ("POST", "/api/cmd"):
            guard authorized(headerText: headerText, target: target) else {
                sendJSON(fd: fd, status: "401 Unauthorized", dict: ["ok": false, "error": "unauthorized"])
                return
            }
            handleAPICommand(fd: fd, body: body)
        default:
            sendError(fd: fd, status: "404 Not Found")
        }
    }

    private func authorized(headerText: String, target: String) -> Bool {
        guard !token.isEmpty else { return false }
        if let value = Self.headerValue("authorization", in: headerText),
            constantTimeEquals(value, "Bearer \(token)")
        {
            return true
        }
        if let queryStart = target.firstIndex(of: "?") {
            let query = target[target.index(after: queryStart)...]
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "token", constantTimeEquals(String(kv[1]), token) {
                    return true
                }
            }
        }
        return false
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private func handleAPICommand(fd: Int32, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let cmd = json["cmd"] as? String
        else {
            sendJSON(fd: fd, status: "400 Bad Request", dict: ["ok": false, "error": "invalid json"])
            return
        }
        guard Self.allowedCommands.contains(cmd) else {
            sendJSON(fd: fd, status: "403 Forbidden", dict: ["ok": false, "error": "command not allowed: \(cmd)"])
            return
        }
        guard let handler = onCommand else {
            sendJSON(fd: fd, status: "503 Service Unavailable", dict: ["ok": false, "error": "no handler"])
            return
        }
        handler(cmd, json) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                // Client may have disconnected while the command ran.
                guard self.clientSources[fd] != nil else { return }
                self.sendJSON(fd: fd, status: "200 OK", dict: response)
            }
        }
    }

    // MARK: - Responses

    /// Web UI page, read from the bundle once — it never changes during a run.
    private static let indexHTML: Data? = {
        guard
            let url = BooResourceBundle.bundle.url(
                forResource: "index", withExtension: "html", subdirectory: "RemoteControl")
        else { return nil }
        return try? Data(contentsOf: url)
    }()

    private func serveIndex(fd: Int32) {
        guard let html = Self.indexHTML else {
            sendError(fd: fd, status: "500 Internal Server Error")
            return
        }
        sendResponse(fd: fd, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
    }

    /// libghostty-vt WebAssembly module used by the web UI terminal renderer.
    private static let wasmModule: Data? = {
        guard
            let url = BooResourceBundle.bundle.url(
                forResource: "ghostty-vt", withExtension: "wasm", subdirectory: "RemoteControl")
        else { return nil }
        return try? Data(contentsOf: url)
    }()

    private func serveWasm(fd: Int32) {
        guard let wasm = Self.wasmModule else {
            sendError(fd: fd, status: "404 Not Found")
            return
        }
        sendResponse(fd: fd, status: "200 OK", contentType: "application/wasm", body: wasm)
    }

    private func sendJSON(fd: Int32, status: String, dict: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        sendResponse(fd: fd, status: status, contentType: "application/json", body: data)
    }

    private func sendError(fd: Int32, status: String) {
        sendResponse(fd: fd, status: status, contentType: "text/plain", body: Data(status.utf8))
    }

    private func sendResponse(fd: Int32, status: String, contentType: String, body: Data) {
        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\n".utf8))
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Cache-Control: no-store\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        writeAll(fd: fd, data: response)
        clientSources[fd]?.cancel()
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = send(fd, base.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, 1000) > 0,
                        descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
                    else { return }
                default:
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Fallback: UUID-derived (still unpredictable enough for a LAN session token)
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// First non-loopback IPv4 address (prefers en0).
    static func lanIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(cString: host)
            let name = String(cString: ifa.pointee.ifa_name)
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}
