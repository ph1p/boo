import CGhostty
import Foundation

/// Receives tmux control-mode traffic from a surface where `tmux -CC` runs.
/// Ghostty calls back on its IO thread with the terminal locked, so events are
/// queued here and handed to the main thread in batches.
final class TmuxGatewayTap: @unchecked Sendable {
    enum Event {
        case enter
        case line([UInt8])
        case exit
    }

    /// Runs on the main thread with the events in arrival order.
    var onEvents: (@MainActor ([Event]) -> Void)?

    private let lock = NSLock()
    private var queued: [Event] = []
    private var drainScheduled = false

    func install(surface: ghostty_surface_t) {
        // Unretained: the owning GhosttyView keeps the tap alive and detaches
        // before releasing it.
        ghostty_surface_set_tmux_callback(surface, Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Clears the callback. The setter takes the terminal lock, so no
    /// callback runs after it returns.
    func detach(surface: ghostty_surface_t?) {
        if let surface { ghostty_surface_set_tmux_callback(surface, nil, nil) }
    }

    private func enqueue(_ event: Event) {
        let schedule = lock.withLock {
            queued.append(event)
            defer { drainScheduled = true }
            return !drainScheduled
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let events = lock.withLock {
                    drainScheduled = false
                    defer { queued.removeAll(keepingCapacity: true) }
                    return queued
                }
                onEvents?(events)
            }
        }
    }

    nonisolated private static let callback: ghostty_surface_tmux_cb = { userdata, kind, bytes, len in
        guard let userdata else { return }
        let tap = Unmanaged<TmuxGatewayTap>.fromOpaque(userdata).takeUnretainedValue()
        switch kind {
        case 0: tap.enqueue(.enter)
        case 1: tap.enqueue(.line(bytes.map { Array(UnsafeBufferPointer(start: $0, count: Int(len))) } ?? []))
        default: tap.enqueue(.exit)
        }
    }
}
