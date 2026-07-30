import Foundation

// MARK: - Monotonic Clock

/// Seconds since boot, from a monotonic source.
///
/// `Date`/wall-clock is wrong for TTLs and elapsed-time checks — an NTP step or a
/// user clock change can make an interval negative or huge. Every cache/TTL in Boo
/// measures against this.
func booUptime() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// MARK: - Process Timeout Helper

extension Process {
    /// Launch the process and wait for it to exit, terminating it if it exceeds the timeout.
    /// `terminationHandler` is set before `run()` to eliminate the race where a fast-exiting
    /// process finishes before the handler is registered, leaving the semaphore unsignalled.
    ///
    /// `escalateAfter` sends `SIGKILL` when the process ignores the `SIGTERM` from a timeout
    /// (a wedged `ssh` stuck in auth does exactly that). Pass nil to skip escalation.
    ///
    /// Returns true if the process exited within the timeout with status 0.
    @discardableResult
    func runAndWait(seconds: TimeInterval, escalateAfter: TimeInterval? = nil) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        terminationHandler = { _ in sem.signal() }
        do { try run() } catch { return false }
        guard sem.wait(timeout: .now() + seconds) == .timedOut else {
            return terminationStatus == 0
        }
        terminate()
        if let escalateAfter, sem.wait(timeout: .now() + escalateAfter) == .timedOut {
            kill(processIdentifier, SIGKILL)
            _ = sem.wait(timeout: .now() + escalateAfter)
        }
        return false
    }
}
