import Foundation

/// Tail of a process's stderr, drained as it arrives so a chatty kubectl
/// (deprecation warnings, auth plugin noise) never blocks on a full pipe.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 8192 { data = data.suffix(4096) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One `kubectl get <kind> -w` process, restarted with backoff when it exits.
@MainActor
final class KubeWatch {
    let kind: KubeKind
    let kubectl: String
    let context: String
    let namespace: String
    /// Events of one read, delivered together so the store publishes once.
    var onEvents: (([KubeWatchEvent]) -> Void)?
    var onError: ((String) -> Void)?
    /// About to restart: the new process re-lists everything.
    var onRelist: (() -> Void)?

    private var process: Process?
    private var stopped = false
    private var failures = 0
    private var startedAt = Date()

    init(kind: KubeKind, kubectl: String, context: String, namespace: String) {
        self.kind = kind
        self.kubectl = kubectl
        self.context = context
        self.namespace = namespace
    }

    func start() {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = [
            "--context", context, "-n", namespace, "get", kind.rawValue, "--watch", "--output-watch-events", "-o",
            "json"
        ]
        process.environment = KubeStore.environment(wait: false)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // The handler runs serially on a background queue; only it touches the splitter.
        nonisolated(unsafe) var splitter = JSONObjectStreamSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = splitter.feed(data).compactMap(KubeWatchEvent.parse)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.failures = 0
                    self.onEvents?(events)
                }
            }
        }
        let tail = StderrTail()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        process.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            tail.append(err.fileHandleForReading.readDataToEndOfFile())
            let stderr = tail.text
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status: status, stderr: stderr) }
            }
        }
        startedAt = Date()
        do {
            try process.run()
            self.process = process
        } catch {
            exited(status: -1, stderr: error.localizedDescription)
        }
    }

    func stop() {
        stopped = true
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// Watches end on their own (server timeouts, network); relist after a backoff.
    private func exited(status: Int32, stderr: String) {
        guard !stopped else { return }
        process = nil
        // A watch that ran a while ended normally; restart promptly.
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 } else { failures += 1 }
        if status != 0, let line = KubeStore.lastLine(stderr) {
            onError?(line)
        }
        let delay = failures == 0 ? 1 : min(30, pow(2, Double(min(failures, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.onRelist?()
            self.start()
        }
    }
}
