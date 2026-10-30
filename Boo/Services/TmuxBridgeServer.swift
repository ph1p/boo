import Darwin
import Foundation

/// Unix socket that `Boo --tmux-bridge` processes connect to. Each bridge
/// introduces itself with the token Boo put on its command line; the token
/// picks the handler that receives its keystrokes and size, and the bridge
/// receives that pane's output.
final class TmuxBridgeServer: @unchecked Sendable {
    static let shared = TmuxBridgeServer()

    enum Event: Sendable {
        case connected
        case input([UInt8])
        case resize(TmuxProtocol.CellSize)
        case disconnected
    }

    typealias Handler = @MainActor @Sendable (Event) -> Void

    let socketPath: String

    init(socketPath: String = (BooPaths.configDir as NSString).appendingPathComponent("tmux-\(getpid()).sock")) {
        self.socketPath = socketPath
    }

    private let queue = DispatchQueue(label: "boo.tmux-bridge")
    private lazy var core = SocketServerCore(
        queue: queue,
        config: .init(
            maxClients: 256, maxBufferBytes: 1 << 20, idleTimeout: nil, writeTimeout: 2,
            readChunk: 16 * 1024, logLabel: "TmuxBridge"),
        delegate: self)
    private var started = false
    // Queue-confined.
    private var handlers: [String: Handler] = [:]
    private var tokenOfFD: [Int32: String] = [:]
    private var fdOfToken: [String: Int32] = [:]

    /// A fresh token routed to `handler`, and the command that runs the bridge.
    func register(_ handler: @escaping Handler) -> (token: String, command: String) {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        queue.sync {
            startIfNeeded()
            handlers[token] = handler
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let quote = LinkResolver.shellQuote
        return (token, "exec \(quote(exe)) --tmux-bridge \(quote(socketPath)) \(token)")
    }

    /// Forgets `token` and closes its bridge, which then exits.
    func unregister(_ token: String) {
        queue.async { [self] in
            handlers[token] = nil
            if let fd = fdOfToken.removeValue(forKey: token) {
                tokenOfFD[fd] = nil
                core.drop(fd: fd)
            }
        }
    }

    func send(_ token: String, _ bytes: [UInt8]) {
        queue.async { [self] in
            guard let fd = fdOfToken[token] else { return }
            _ = core.write(fd: fd, Data(bytes))
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        guard let fd = UnixSocket.listen(path: socketPath, backlog: 16, label: "TmuxBridge") else { return }
        core.adoptListener(fd: fd)
    }

    /// Removes the socket file at quit.
    func shutdown() {
        queue.sync {
            guard started else { return }
            core.shutdown()
            unlink(socketPath)
        }
    }

    private func dispatch(_ token: String, _ event: Event) {
        guard let handler = handlers[token] else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }
}

extension TmuxBridgeServer: SocketServerCore.Delegate {
    func socketServerShouldAccept(fd: Int32) -> Bool {
        UnixSocket.peerIsSameUser(fd: fd)
    }

    func socketServerConsume(buffer: Data, fd: Int32) -> Int? {
        guard let token = tokenOfFD[fd] else {
            // First line: the token.
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return buffer.count > 64 ? nil : 0 }
            let token = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            guard handlers[token] != nil, fdOfToken[token] == nil else { return nil }
            tokenOfFD[fd] = token
            fdOfToken[token] = fd
            dispatch(token, .connected)
            return buffer.distance(from: buffer.startIndex, to: newline) + 1
        }
        switch TmuxProtocol.decode(buffer) {
        case .incomplete: return 0
        case .malformed: return nil
        case .frame(.input(let bytes), let consumed):
            dispatch(token, .input(bytes))
            return consumed
        case .frame(.resize(let size), let consumed):
            dispatch(token, .resize(size))
            return consumed
        }
    }

    func socketServerDidCloseClient(fd: Int32) {
        guard let token = tokenOfFD.removeValue(forKey: fd) else { return }
        fdOfToken[token] = nil
        dispatch(token, .disconnected)
    }
}
