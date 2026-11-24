import Foundation

/// Lets a cancelled MCP request abort its socket read: `cancel()` shuts the
/// connection down, so the blocked read returns at once.
final class BooMCPCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Binds the open socket. False when the request was already cancelled.
    func attach(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.fd = fd
            return true
        }
    }

    /// Called before the socket is closed.
    func detach() {
        lock.withLock { fd = -1 }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }
}

/// Reads JSON-RPC lines and answers them without one slow call blocking the
/// rest: `tools/call` runs on its own thread (`wait_for_events` can wait
/// minutes, a browser load over a minute), protocol messages answer at once.
/// `notifications/cancelled` aborts a running call and drops its reply.
final class BooMCPDispatcher: @unchecked Sendable {
    typealias Handle = ([String: Any], BooMCPCancel) -> [String: Any]?

    private let handle: Handle
    private let write: (Data) -> Void
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var running: [String: BooMCPCancel] = [:]
    private let calls = DispatchGroup()
    private let queue = DispatchQueue(label: "boo.mcp.calls", attributes: .concurrent)

    init(handle: @escaping Handle, write: @escaping (Data) -> Void) {
        self.handle = handle
        self.write = write
    }

    func receive(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let data = line.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            send(BooMCPServer.errorResponse(id: NSNull(), code: -32700, message: "parse error"))
            return
        }
        let method = message["method"] as? String
        if method == "notifications/cancelled" {
            let params = message["params"] as? [String: Any]
            if let id = params?["requestId"] {
                lock.withLock { running[Self.key(id)] }?.cancel()
            }
            return
        }
        guard method == "tools/call", let id = message["id"], !(id is NSNull) else {
            if let response = handle(message, BooMCPCancel()) { send(response) }
            return
        }
        let key = Self.key(id)
        let cancel = BooMCPCancel()
        lock.withLock { running[key] = cancel }
        calls.enter()
        queue.async { [self] in
            defer { calls.leave() }
            let response = handle(message, cancel)
            lock.withLock {
                if running[key] === cancel { running[key] = nil }
            }
            // A cancelled request gets no reply (MCP: the client has moved on).
            guard !cancel.isCancelled, let response else { return }
            send(response)
        }
    }

    /// Blocks until every running call has answered.
    func waitForCalls() {
        calls.wait()
    }

    /// One line per reply; the lock keeps concurrent replies from interleaving.
    private func send(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
        else { return }
        writeLock.withLock { write(data + Data("\n".utf8)) }
    }

    /// JSON-RPC ids are numbers or strings; keep 1 and "1" apart.
    private static func key(_ id: Any) -> String {
        if let string = id as? String { return "s:" + string }
        return "n:\(id)"
    }
}
