import Darwin
import Foundation
import Security

/// HTTP server exposing a web interface to control Boo remotely.
/// Serves an embedded single-page UI plus a JSON command API. Commands are
/// routed to MainActor handlers via `onCommand` (wired by MainWindowController).
///
/// Security: every API request must carry the session token (regenerated on
/// each start) via `Authorization: Bearer <token>`. The UI receives it in the URL
/// fragment, which browsers never put on the wire.
/// Connections use `Connection: close` — the UI polls, no keep-alive needed.
/// Idle connections are dropped after `requestTimeout` so a handful of silent
/// sockets can't exhaust `maxClients`.
///
/// Thread safety: all socket I/O happens on `queue`. Public accessors
/// snapshot state synchronously via `queue.sync`.
final class RemoteControlServer: @unchecked Sendable {
    static let shared = RemoteControlServer()

    /// Command handler — receives (cmd, json, reply). Reply may be called from
    /// any thread; the server serializes the response and closes the socket.
    var onCommand: ((_ cmd: String, _ json: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "com.boo.remotecontrol", qos: .utility)

    private static let maxRequestBytes = 65536

    /// Owns the sockets, client tables, accept limit, idle deadlines and budgeted
    /// writes; this class supplies only the HTTP framing via `Delegate`.
    private lazy var core = SocketServerCore(
        queue: queue,
        config: SocketServerCore.Config(
            maxClients: 32,
            maxBufferBytes: Self.maxRequestBytes,
            // `Connection: close` — a connection that hasn't delivered a complete
            // request in this long is a slot held for nothing.
            idleTimeout: 15,
            writeTimeout: 5,
            readChunk: 8192,
            logLabel: "RemoteControl"
        ),
        delegate: self
    )

    /// Commands accepted from the web API.
    private static let allowedCommands: Set<String> = [
        "get_state", "get_screen", "send_text", "send_key",
        "switch_workspace", "select_tab", "new_tab", "select_pane"
    ]

    private(set) var token: String = ""
    private(set) var port: UInt16 = 0

    var isRunning: Bool { queue.sync { core.isListening } }

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
            guard !core.isListening else { return true }

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

            port = requestedPort
            token = Self.generateToken()
            core.adoptListener(fd: fd)

            booLog(.info, .socket, "RemoteControl: listening on :\(requestedPort)")
            return true
        }
    }

    func stop() {
        queue.sync {
            core.shutdown()
            token = ""
            booLog(.info, .socket, "RemoteControl: stopped")
        }
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
            guard authorized(headerText: headerText) else {
                sendJSON(fd: fd, status: "401 Unauthorized", dict: ["ok": false, "error": "unauthorized"])
                return
            }
            handleAPICommand(fd: fd, body: body)
        default:
            sendError(fd: fd, status: "404 Not Found")
        }
    }

    /// Authorize via `Authorization: Bearer <token>` only.
    ///
    /// The token deliberately isn't accepted as a query parameter: request targets
    /// end up in browser history, proxy logs and `Referer` headers, and the web UI
    /// carries the token in the URL *fragment* (never sent to the server) precisely
    /// to avoid that. Header-only keeps the single intended path.
    private func authorized(headerText: String) -> Bool {
        guard !token.isEmpty else { return false }
        guard let value = Self.headerValue("authorization", in: headerText) else { return false }
        return constantTimeEquals(value, "Bearer \(token)")
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
            // Encode here rather than inside the queue hop: `[String: Any]` is not
            // Sendable, and this keeps JSON serialization off the shared serial queue.
            let body = Self.jsonBody(response)
            self.queue.async {
                // Client may have disconnected while the command ran; writing to a
                // reused descriptor would answer the wrong request.
                guard self.core.connectedFDs.contains(fd) else { return }
                self.sendResponse(fd: fd, status: "200 OK", contentType: "application/json", body: body)
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

    /// Encode a response dict, falling back to an empty object so a non-encodable
    /// value still produces a well-formed reply rather than a dropped connection.
    private static func jsonBody(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    private func sendJSON(fd: Int32, status: String, dict: [String: Any]) {
        sendResponse(fd: fd, status: status, contentType: "application/json", body: Self.jsonBody(dict))
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
        // The UI holds a live terminal, and the token travels in the URL fragment:
        // deny framing so no page can clickjack it, and suppress Referer so the
        // fragment can't leak to a third party via an outbound link.
        response.append(Data("X-Content-Type-Options: nosniff\r\n".utf8))
        response.append(Data("X-Frame-Options: DENY\r\n".utf8))
        response.append(Data("Referrer-Policy: no-referrer\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        core.write(fd: fd, response)
        // `Connection: close`: the response is the whole conversation.
        core.drop(fd: fd)
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
            // Bit-pattern, not `UInt8.init`: high-bit bytes are negative as `CChar` and
            // the checked initialiser would trap on them.
            let address = String(
                decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: ifa.pointee.ifa_name)
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}

// MARK: - Framing

extension RemoteControlServer: SocketServerCore.Delegate {

    /// No peer check: this listens on the LAN by design, and the bearer token is
    /// what authorizes a request.
    func socketServerShouldAccept(fd: Int32) -> Bool { true }

    /// HTTP/1.1 with `Connection: close`, so at most one request per connection:
    /// headers terminated by CRLFCRLF plus `Content-Length` bytes of body.
    func socketServerConsume(buffer: Data, fd: Int32) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return 0 }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let contentLength = Self.contentLength(fromHeaders: headerText)
        guard contentLength >= 0, contentLength <= Self.maxRequestBytes else { return nil }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return 0 }  // await body

        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        // Responds and closes, so anything pipelined behind this is discarded —
        // consistent with the `Connection: close` we advertise.
        handleRequest(fd: fd, headerText: headerText, body: body)
        return consumed
    }

    func socketServerDidCloseClient(fd: Int32) {}
}
