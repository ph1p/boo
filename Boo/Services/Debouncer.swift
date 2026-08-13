import Foundation

/// Coalesces a burst of triggers into one main-queue call after a quiet interval.
///
/// Replaces the hand-rolled `DispatchWorkItem` + `asyncAfter` + `cancel` triple that
/// several services had each grown their own copy of. Owning one of these instead of a
/// bare work item makes the cancel-on-teardown obligation part of the type: `cancel()`
/// is the whole API, and a dropped `Debouncer` simply stops firing (the pending block is
/// expected to capture `self` weakly, exactly as the inline versions did).
final class Debouncer {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Schedule `block`, discarding any call still waiting from an earlier trigger.
    /// `delay` overrides the default for this one call — useful when several triggers
    /// share one debouncer (so they coalesce with each other) but deserve different
    /// latencies.
    func schedule(delay: TimeInterval? = nil, _ block: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            MainActor.assumeIsolated { block() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? self.delay), execute: work)
    }

    /// Drop a call that has not fired yet. Safe to call when nothing is pending.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Whether a call is waiting to fire.
    var isPending: Bool { pending != nil }
}
