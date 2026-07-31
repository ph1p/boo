import Darwin
import Foundation

/// Byte-stream transport shared by Boo's two hand-rolled socket servers
/// (`BooSocketServer` over `AF_UNIX`, `RemoteControlServer` over `AF_INET`).
///
/// The core owns everything below the message boundary: the listening socket's
/// accept source, the per-connection read sources and buffers, the client limit,
/// idle deadlines, budgeted writes, and teardown ordering. It deliberately does
/// *not* know how bytes group into messages — a delegate decides that, so HTTP
/// parsing never becomes a dependency of the IPC server or vice versa.
///
/// Thread safety: every method must be called on `queue`, and every delegate
/// callback is invoked there. `queue` is supplied by the owner so an existing
/// server can keep the queue its public accessors already synchronise on.
final class SocketServerCore: @unchecked Sendable {

    /// Framing and admission policy, supplied by the owning server.
    ///
    /// All callbacks run on the core's `queue`.
    protocol Delegate: AnyObject {
        /// Decide whether to admit a freshly accepted connection.
        /// Return false to close it immediately (peer credential checks, etc.).
        func socketServerShouldAccept(fd: Int32) -> Bool

        /// Consume as much of `buffer` as forms complete messages.
        ///
        /// Return the number of leading bytes consumed — 0 means "incomplete
        /// message, wait for more" — or nil to drop the connection (malformed
        /// input). Returning a count larger than `buffer.count` is a programmer
        /// error and traps.
        func socketServerConsume(buffer: Data, fd: Int32) -> Int?

        /// A connection went away. Release any per-fd state the owner holds.
        /// The core has already closed the descriptor and dropped its own tables.
        func socketServerDidCloseClient(fd: Int32)
    }

    /// Tunables that differ between the two servers.
    struct Config {
        /// Maximum concurrent connections; further accepts are closed immediately.
        var maxClients: Int
        /// Cap on a single connection's unconsumed buffer, to bound memory.
        var maxBufferBytes: Int
        /// Idle budget for a connection to deliver a complete message.
        /// Nil disables the deadline — correct for long-lived subscriber clients.
        var idleTimeout: TimeInterval?
        /// Total time one `write` may block `queue` waiting on a slow peer.
        var writeTimeout: TimeInterval
        /// Bytes per `read()` call.
        var readChunk: Int
        /// Prefix for this server's log lines.
        var logLabel: String
    }

    let queue: DispatchQueue
    private let config: Config
    private weak var delegate: Delegate?

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    /// Per-connection idle deadlines. Without them a peer that connects and never
    /// finishes a message holds a slot forever, so `maxClients` silent connections
    /// lock every real request out until the process restarts.
    private var clientTimers: [Int32: DispatchSourceTimer] = [:]

    init(queue: DispatchQueue, config: Config, delegate: Delegate) {
        self.queue = queue
        self.config = config
        self.delegate = delegate
    }

    /// Descriptors of the currently connected clients.
    var connectedFDs: [Int32] { Array(clientSources.keys) }

    var isListening: Bool { serverFD >= 0 }

    // MARK: - Lifecycle

    /// Take ownership of an already-bound, already-listening socket.
    ///
    /// Binding stays with the owner because it is the one genuinely
    /// family-specific step (`sockaddr_un` + chmod vs `sockaddr_in` +
    /// `SO_REUSEADDR`); everything after it is identical.
    func adoptListener(fd: Int32) {
        serverFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            guard let self, self.serverFD >= 0 else { return }
            close(self.serverFD)
            self.serverFD = -1
        }
        source.resume()
        acceptSource = source
    }

    /// Drop every connection and stop listening. Safe to call when not listening.
    func shutdown() {
        acceptSource?.cancel()
        acceptSource = nil
        // Cancelling a read source runs its cancel handler, which is the single
        // owner of per-connection teardown — including the timer and the buffer.
        for source in clientSources.values {
            source.cancel()
        }
        // The handlers run asynchronously on `queue`; clear now so a shutdown
        // followed by a restart on the same queue iteration sees empty tables.
        for timer in clientTimers.values {
            timer.cancel()
        }
        clientTimers.removeAll()
        clientSources.removeAll()
        clientBuffers.removeAll()
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
    }

    // MARK: - Accept

    private func acceptClient() {
        guard serverFD >= 0 else { return }
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Over the limit: accept-then-close rather than leaving it queued, or the
        // level-triggered read source spins on the still-pending connection.
        guard clientSources.count < config.maxClients else {
            close(clientFD)
            return
        }
        guard delegate?.socketServerShouldAccept(fd: clientFD) == true else {
            close(clientFD)
            return
        }

        configureClientSocket(clientFD)
        clientBuffers[clientFD] = Data()

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(fd: clientFD) }
        source.setCancelHandler { [weak self] in
            close(clientFD)
            guard let self else { return }
            self.clientBuffers.removeValue(forKey: clientFD)
            self.clientSources.removeValue(forKey: clientFD)
            self.clientTimers.removeValue(forKey: clientFD)?.cancel()
            self.delegate?.socketServerDidCloseClient(fd: clientFD)
        }
        source.resume()
        clientSources[clientFD] = source

        armIdleTimer(fd: clientFD)
    }

    /// Non-blocking so a slow peer can never stall the shared queue in `send`,
    /// and `SO_NOSIGPIPE` so writing to a closed peer returns EPIPE instead of
    /// killing the process.
    private func configureClientSocket(_ fd: Int32) {
        var flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func armIdleTimer(fd: Int32) {
        guard let idleTimeout = config.idleTimeout else { return }
        clientTimers.removeValue(forKey: fd)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, let stalled = self.clientSources[fd] else { return }
            booLog(.info, .socket, "\(self.config.logLabel): dropping idle client after \(idleTimeout)s")
            stalled.cancel()
        }
        timer.resume()
        clientTimers[fd] = timer
    }

    // MARK: - Read

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: config.readChunk)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            // 0 is orderly shutdown; EAGAIN on a level-triggered source just means
            // another handler already drained it, so only a real error drops here.
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            drop(fd: fd)
            return
        }
        clientBuffers[fd]?.append(contentsOf: buf[0..<n])

        guard let buffer = clientBuffers[fd] else { return }
        guard buffer.count <= config.maxBufferBytes else {
            booLog(.info, .socket, "\(config.logLabel): client exceeded \(config.maxBufferBytes) bytes, dropping")
            drop(fd: fd)
            return
        }

        // Progress on the wire refreshes the deadline: it exists to reap silent
        // connections, not to cut off a peer that is still sending.
        armIdleTimer(fd: fd)
        deliver(fd: fd)
    }

    /// Hand buffered bytes to the delegate until it stops consuming.
    private func deliver(fd: Int32) {
        while let buffer = clientBuffers[fd], !buffer.isEmpty {
            guard let consumed = delegate?.socketServerConsume(buffer: buffer, fd: fd) else {
                drop(fd: fd)
                return
            }
            guard consumed > 0 else { return }  // incomplete message, await more bytes
            precondition(consumed <= buffer.count, "delegate consumed more bytes than were available")
            // Re-read the table: the delegate may have written a response and, on
            // failure, already dropped this client out from under us.
            guard clientBuffers[fd] != nil else { return }
            clientBuffers[fd] = Data(buffer.dropFirst(consumed))
        }
    }

    // MARK: - Write

    /// Close a connection and run its teardown.
    func drop(fd: Int32) {
        clientSources[fd]?.cancel()
    }

    /// Send `data` in full, returning false if the peer died or exhausted its
    /// write budget. A false return has already dropped the connection.
    @discardableResult
    func write(fd: Int32, _ data: Data) -> Bool {
        guard writeAll(fd: fd, data: data) else {
            drop(fd: fd)
            return false
        }
        return true
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        // Monotonic clock, not `Date()`: a wall-clock step (NTP, manual change)
        // would make the remaining interval negative or effectively infinite.
        let deadline = booUptime() + config.writeTimeout
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = send(fd, base.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return false }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    // The only branch that blocks, so the only one that needs the
                    // deadline — the success path stays free of clock reads.
                    //
                    // A per-poll cap alone is not enough: a peer that reads just
                    // enough to keep POLLOUT flapping makes a byte of progress per
                    // poll and would spin here forever, stalling the shared queue.
                    guard booUptime() < deadline else {
                        booLog(.info, .socket, "\(config.logLabel): write budget exhausted, dropping client fd=\(fd)")
                        return false
                    }
                    guard waitUntilWritable(fd: fd) else { return false }
                default:
                    return false
                }
            }
            return true
        }
    }

    private func waitUntilWritable(fd: Int32, timeoutMS: Int32 = 250) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let result = poll(&descriptor, 1, timeoutMS)
            if result > 0 {
                guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
                return descriptor.revents & Int16(POLLOUT) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }
}
