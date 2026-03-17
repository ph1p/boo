import Foundation
import Darwin

final class TerminalSession {
    private weak var terminalView: TerminalView?
    private let initialDirectory: String
    let terminal: VT100Terminal
    private var process: PTYProcess?
    private var readSource: DispatchSourceRead?
    private var pollTimer: Timer?  // unified CWD + SSH poll

    private(set) var currentDirectory: String
    var onDirectoryChanged: ((String) -> Void)?

    /// Remote session detection (SSH, Docker)
    private(set) var remoteSession: RemoteSessionType?
    private(set) var remoteCwd: String?
    private var remoteDetectedAt: Date?  // when the remote process was first seen
    private var remoteConnected = false  // whether we've successfully run a remote command
    private var remoteConnectionFailed = false  // gave up connecting after timeout
    var onRemoteStateChanged: ((RemoteSessionType?, String?) -> Void)?
    var onRemoteConnectionFailed: ((RemoteSessionType) -> Void)?

    init(terminalView: TerminalView, workingDirectory: String) {
        self.terminalView = terminalView
        self.initialDirectory = workingDirectory
        self.currentDirectory = workingDirectory
        self.terminal = VT100Terminal()
        attachToView(terminalView)
    }

    /// Disconnect from the terminal view (session keeps running in background).
    func detachFromView() {
        terminalView?.terminal = nil
        terminalView?.onInput = nil
        terminalView?.onResize = nil
        terminalView = nil
    }

    /// Reattach this session to a (possibly new) terminal view.
    func attachToView(_ view: TerminalView) {
        self.terminalView = view
        view.terminal = terminal
        view.onInput = { [weak self] data in
            self?.process?.write(data)
        }
        view.onResize = { [weak self] cols, rows in
            self?.handleResize(cols: cols, rows: rows)
        }
        view.needsDisplay = true
    }

    func start() {
        do {
            guard let tv = terminalView else { return }

            var cols = tv.gridCols
            var rows = tv.gridRows
            if cols <= 1 || rows <= 1 {
                cols = 80
                rows = 24
            }

            terminal.resize(cols: cols, rows: rows)

            terminal.onDirectoryChanged = { [weak self] path in
                DispatchQueue.main.async {
                    guard let self = self, path != self.currentDirectory else { return }
                    self.currentDirectory = path
                    self.onDirectoryChanged?(path)
                }
            }

            let process = PTYProcess()
            self.process = process

            try process.spawn(
                cols: UInt16(cols),
                rows: UInt16(rows),
                workingDirectory: initialDirectory
            )

            startReadLoop()
            startPolling()

            tv.onResize = { [weak self] cols, rows in
                self?.handleResize(cols: cols, rows: rows)
            }
        } catch {
            NSLog("[Exterm] Failed to start terminal session: \(error)")
        }
    }

    func writeToPTY(_ data: Data) {
        process?.write(data)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        readSource?.cancel()
        readSource = nil
        process?.terminate()
        process = nil
    }

    private func startReadLoop() {
        guard let masterFD = process?.masterFD, masterFD >= 0 else { return }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        source.setEventHandler { [weak self] in
            guard let self = self, let process = self.process else { return }
            if let data = process.read() {
                self.terminal.feed(data)
                DispatchQueue.main.async {
                    self.terminalView?.needsDisplay = true
                }
            }
        }

        source.setCancelHandler { }

        source.resume()
        self.readSource = source
    }

    // MARK: - CWD Tracking

    // MARK: - Unified CWD + SSH Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let process = process, process.isRunning else { return }
        let pid = process.pid
        guard pid > 0 else { return }

        // CWD poll (fast syscall)
        if let cwd = Self.getCwd(of: pid), cwd != currentDirectory {
            currentDirectory = cwd
            onDirectoryChanged?(cwd)
        }

        // Remote session detection (lightweight pgrep on background)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detected = RemoteExplorer.detectRemoteSession(shellPID: pid)

            DispatchQueue.main.async {
                guard let self = self else { return }

                if detected != self.remoteSession {
                    self.remoteSession = detected
                    self.remoteConnected = false
                    self.remoteConnectionFailed = false

                    if detected != nil {
                        // New remote session detected — notify immediately (shows "connecting...")
                        self.remoteDetectedAt = Date()
                        self.remoteCwd = nil
                        self.onRemoteStateChanged?(detected, nil)
                    } else {
                        // Session ended
                        self.remoteDetectedAt = nil
                        self.remoteCwd = nil
                        self.onRemoteStateChanged?(nil, nil)
                    }
                    return
                }

                // If we have a detected session, try to connect
                guard let session = detected else { return }

                if !self.remoteConnected && !self.remoteConnectionFailed {
                    // Wait a grace period before attempting commands
                    // SSH needs time to authenticate, Docker exec needs time to start shell
                    let grace: TimeInterval = (session == self.remoteSession) ? 1.5 : 3.0
                    guard let detectedAt = self.remoteDetectedAt,
                          Date().timeIntervalSince(detectedAt) > grace else { return }

                    // Give up after 10 seconds of failed attempts
                    let elapsed = Date().timeIntervalSince(detectedAt)
                    let timeout: TimeInterval = 12.0

                    // Try to get remote cwd — this is the connection test
                    RemoteExplorer.getRemoteCwd(session: session) { [weak self] cwd in
                        guard let self = self, self.remoteSession == session else { return }
                        if let cwd = cwd {
                            self.remoteConnected = true
                            self.remoteConnectionFailed = false
                            self.remoteCwd = cwd
                            self.onRemoteStateChanged?(session, cwd)
                        } else if elapsed > timeout {
                            self.remoteConnectionFailed = true
                            self.onRemoteConnectionFailed?(session)
                        }
                        // If nil and not timed out, try again next poll
                    }
                } else {
                    // Already connected — poll for cwd changes
                    RemoteExplorer.getRemoteCwd(session: session) { [weak self] cwd in
                        guard let self = self, let cwd = cwd, cwd != self.remoteCwd else { return }
                        self.remoteCwd = cwd
                        self.onRemoteStateChanged?(session, cwd)
                    }
                }
            }
        }
    }

    private static func getCwd(of pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(size))
        guard result == size else { return nil }
        let path = withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                String(cString: cstr)
            }
        }
        return path.isEmpty ? nil : path
    }

    private func handleResize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        process?.setSize(cols: UInt16(cols), rows: UInt16(rows))
    }

    deinit {
        stop()
    }
}
