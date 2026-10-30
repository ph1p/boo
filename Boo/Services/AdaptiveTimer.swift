import Foundation

/// Repeating timer on a serial queue whose interval can change between fires.
/// Not thread-safe: call it only on `queue`.
final class AdaptiveTimer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private var source: DispatchSourceTimer?
    private(set) var interval: TimeInterval = 0

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Fires every `interval` from now on. Same interval as running: no-op,
    /// so the pending fire keeps its deadline.
    func schedule(interval: TimeInterval) {
        if let source {
            guard interval != self.interval else { return }
            source.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [handler] in handler() }
            source.resume()
            self.source = source
        }
        self.interval = interval
    }

    func cancel() {
        source?.cancel()
        source = nil
        interval = 0
    }

    deinit { source?.cancel() }
}
