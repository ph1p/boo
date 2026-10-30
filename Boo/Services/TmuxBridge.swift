import Darwin
import Foundation

/// `Boo --tmux-bridge <socket> <token>`: the program running in each pane that
/// shows a tmux pane. It puts its terminal in raw mode, forwards typed bytes
/// and size changes to Boo over a Unix socket, and writes what Boo sends back
/// (the tmux pane's output) to the terminal. Exits when Boo closes the socket.
enum TmuxBridge {
    nonisolated(unsafe) private static var resized: sig_atomic_t = 0

    static func run(arguments: [String]) -> Never {
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: Boo --tmux-bridge <socket> <token>\n".utf8))
            exit(2)
        }
        guard let sock = UnixSocket.connect(path: arguments[0]) else {
            FileHandle.standardError.write(Data("tmux bridge: cannot reach Boo\n".utf8))
            exit(1)
        }
        var saved = termios()
        let isTTY = tcgetattr(STDIN_FILENO, &saved) == 0
        if isTTY {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        let status = pump(sock: sock, token: arguments[1])
        if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        exit(status)
    }

    private static func pump(sock: Int32, token: String) -> Int32 {
        signal(SIGWINCH) { _ in TmuxBridge.resized = 1 }
        guard writeAll(sock, Array("\(token)\n".utf8)), sendSize(sock) else { return 1 }
        var fds = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        ]
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if resized != 0 {
                resized = 0
                guard sendSize(sock) else { return 0 }
            }
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if fds[1].revents != 0 {
                let n = read(sock, &buffer, buffer.count)
                if n <= 0 { return 0 }
                guard buffer.withUnsafeBytes({ writeAll(STDOUT_FILENO, UnsafeRawBufferPointer(rebasing: $0[0..<n])) })
                else { return 1 }
            }
            if fds[0].revents != 0 {
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n <= 0 { return 0 }
                guard writeAll(sock, TmuxProtocol.encode(.input(Array(buffer[0..<n])))) else { return 0 }
            }
        }
    }

    private static func sendSize(_ sock: Int32) -> Bool {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return true }
        let size = TmuxProtocol.CellSize(columns: Int(ws.ws_col), rows: Int(ws.ws_row))
        return writeAll(sock, TmuxProtocol.encode(.resize(size)))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { writeAll(fd, $0) }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}
