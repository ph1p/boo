import Foundation

/// Runs external commands to completion: pipes drained while the child
/// runs, a wall-clock timeout, and stdin closed so nothing waits on a prompt.
/// Every one-shot command Boo runs for its own use goes through here.
enum Subprocess {
    /// Result of running an external command to completion.
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run `process` to completion, draining stdout/stderr as it writes and
    /// enforcing a wall-clock timeout.
    ///
    /// Draining while the child runs is required for correctness, not just speed:
    /// the `run(); waitUntilExit(); readDataToEndOfFile()` shape deadlocks as soon as
    /// the child writes more than the ~64KB pipe buffer (e.g. `ls` on a directory
    /// with thousands of entries) — the child blocks on write, so it never exits.
    /// Returns nil only if the process could not be launched or the timeout expired.
    /// A child that ran to completion is always reported, non-zero exit included —
    /// callers that require success check `result.status` themselves, and ones that
    /// want the output regardless (a plugin shelling out to `grep`) still get it.
    static func capture(
        _ process: Process,
        timeout: TimeInterval = 20
    ) -> Result? {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = CaptureBox()
        // EOF arrives as an empty read; that's what completes the box.
        for (handle, isStdout) in [
            (outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)
        ] {
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    box.finish()
                } else {
                    box.append(data, isStdout: isStdout)
                }
            }
        }

        let completed = process.runToCompletion(seconds: timeout, escalateAfter: 2) != .failed
        // Both handlers must see EOF before the buffers are read, or a fast child's
        // tail output is lost. The child is gone by now, so this resolves promptly.
        let drained = box.waitForCompletion(timeout: completed ? 5 : 2)
        for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            handle.readabilityHandler = nil
        }
        guard completed else {
            debugLog("[Subprocess] failed within \(timeout)s: \(process.executableURL?.path ?? "?")")
            return nil
        }
        if !drained {
            debugLog("[Subprocess] drain incomplete: \(process.executableURL?.path ?? "?")")
        }
        let (out, err) = box.strings()
        return Result(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Accumulator for stdout/stderr fed from the pipe readability handlers.
    /// Handlers fire on a private queue; the result is read on the calling thread.
    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private let bothClosed = DispatchSemaphore(value: 0)

        func append(_ data: Data, isStdout: Bool) {
            lock.lock()
            if isStdout { out.append(data) } else { err.append(data) }
            lock.unlock()
        }

        /// Signals once per stream; `waitForCompletion` waits for both.
        func finish() {
            bothClosed.signal()
        }

        func waitForCompletion(timeout: TimeInterval) -> Bool {
            let deadline = DispatchTime.now() + timeout
            return bothClosed.wait(timeout: deadline) == .success
                && bothClosed.wait(timeout: deadline) == .success
        }

        func strings() -> (String, String) {
            lock.lock()
            defer { lock.unlock() }
            return (String(data: out, encoding: .utf8) ?? "", String(data: err, encoding: .utf8) ?? "")
        }
    }

    /// Builds and runs `executable` with `arguments`.
    static func run(
        _ executable: String, _ arguments: [String], in directory: String? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval = 20
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        return capture(process, timeout: timeout)
    }

    /// Stdout of a run that exited 0, else nil.
    static func output(
        _ executable: String, _ arguments: [String], in directory: String? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval = 20
    ) -> String? {
        guard let result = run(executable, arguments, in: directory, environment: environment, timeout: timeout),
            result.status == 0
        else { return nil }
        return result.stdout
    }
}
