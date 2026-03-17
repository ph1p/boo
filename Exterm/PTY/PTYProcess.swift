import Foundation
import Darwin
import CPTYHelper

final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    private(set) var isRunning = false
    var onExited: (() -> Void)?

    func spawn(
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        shell: String? = nil,
        workingDirectory: String = NSHomeDirectory()
    ) throws {
        let shellPath = shell ?? defaultShell()

        var master: Int32 = -1
        let childPid = pty_fork(&master, rows, cols)

        guard childPid >= 0 else {
            throw ProcessError.forkFailed(errno: errno)
        }

        if childPid == 0 {
            // Child process
            shellPath.withCString { shellCStr in
                workingDirectory.withCString { cwdCStr in
                    pty_exec_shell(shellCStr, cwdCStr)
                }
            }
            _exit(1) // Should not reach here
        }

        // Parent process
        self.masterFD = master
        self.pid = childPid
        self.isRunning = true

        // Set non-blocking on master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        monitorChildProcess()
    }

    func setSize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(masterFD, ptr + offset, remaining)
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                offset += written
                remaining -= written
            }
        }
    }

    func read(maxBytes: Int = 8192) -> Data? {
        guard masterFD >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let bytesRead = Darwin.read(masterFD, &buffer, maxBytes)
        if bytesRead > 0 {
            return Data(buffer[0..<bytesRead])
        }
        return nil
    }

    func terminate() {
        guard isRunning, pid > 0 else { return }
        kill(pid, SIGHUP)
        kill(pid, SIGTERM)
        isRunning = false
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private func monitorChildProcess() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            DispatchQueue.main.async {
                self.isRunning = false
                self.onExited?()
            }
        }
    }

    deinit {
        terminate()
    }
}

enum ProcessError: Error {
    case forkFailed(errno: Int32)
}
