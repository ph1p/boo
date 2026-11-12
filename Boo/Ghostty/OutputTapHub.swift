import CGhostty
import Foundation

/// Receives a surface's raw pty output. Both calls run on Ghostty's io thread
/// with the terminal lock held: copy what you need and return.
protocol OutputTapSubscriber: AnyObject, Sendable {
    func tapOutput(_ bytes: UnsafeBufferPointer<UInt8>)
    func tapResized(columns: Int, rows: Int)
    /// The surface is going away; no more output will arrive. Runs on the
    /// thread tearing the surface down, usually main.
    func tapDetached()
}

extension OutputTapSubscriber {
    func tapDetached() {}
}

/// Owns a surface's single output-callback slot and fans the bytes out to
/// every subscriber (session recorder, trigger matcher, remote streams). The C
/// callback is installed only while there is at least one subscriber, so a
/// surface with nothing listening pays nothing.
final class OutputTapHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: OutputTapSubscriber] = [:] {
        didSet { current = Array(subscribers.values) }
    }
    /// `subscribers.values`, kept so delivery per chunk doesn't build an array.
    private var current: [OutputTapSubscriber] = []
    /// The subscriber that alone receives the terminal snapshot replayed while
    /// it is being added. Snapshot bytes arrive on the calling (main) thread;
    /// live output never does.
    private var snapshotTarget: ObjectIdentifier?
    /// Snapshot subscribers that have not received their snapshot yet. When the
    /// callback is already installed, the io thread can emit output between
    /// registering the subscriber and replaying its snapshot; that output is
    /// already part of the snapshot, so delivering it too would double it.
    private var awaiting: Set<ObjectIdentifier> = []
    private var installed = false

    /// Adds `subscriber`. With `snapshot`, it first receives the grid size and
    /// the current screen as VT sequences; other subscribers don't.
    func add(_ subscriber: OutputTapSubscriber, snapshot: Bool, surface: ghostty_surface_t?) {
        let id = ObjectIdentifier(subscriber)
        lock.withLock {
            subscribers[id] = subscriber
            if snapshot {
                snapshotTarget = id
                awaiting.insert(id)
            }
        }
        if let surface, snapshot || !installed {
            install(surface: surface, snapshot: snapshot)
        }
        lock.withLock {
            snapshotTarget = nil
            awaiting.remove(id)
        }
    }

    /// Removes `subscriber`; clears the C callback once nobody is left. The
    /// setter takes the terminal lock, so no callback runs after it returns.
    func remove(_ subscriber: OutputTapSubscriber, surface: ghostty_surface_t?) {
        let empty = lock.withLock {
            subscribers[ObjectIdentifier(subscriber)] = nil
            return subscribers.isEmpty
        }
        if empty { detach(surface: surface) }
    }

    /// Clears the callback regardless of subscribers (surface teardown) and
    /// tells every remaining subscriber that no more output will come.
    func detach(surface: ghostty_surface_t?) {
        let remaining = lock.withLock { current }
        for s in remaining { s.tapDetached() }
        guard installed else { return }
        if let surface { ghostty_surface_set_output_callback(surface, nil, nil, nil, false) }
        installed = false
    }

    private func install(surface: ghostty_surface_t, snapshot: Bool) {
        // Unretained: the owning GhosttyView keeps the hub alive and detaches
        // before releasing it.
        let token = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_output_callback(surface, Self.outputCB, Self.resizeCB, token, snapshot)
        installed = true
    }

    private func targets() -> [OutputTapSubscriber] {
        lock.withLock {
            if let snapshotTarget, Thread.isMainThread {
                // The snapshot replays under the terminal lock, so once it
                // starts, every later io-thread chunk follows it.
                awaiting.remove(snapshotTarget)
                return subscribers[snapshotTarget].map { [$0] } ?? []
            }
            if awaiting.isEmpty { return current }
            return current.filter { !awaiting.contains(ObjectIdentifier($0)) }
        }
    }

    fileprivate func deliver(_ bytes: UnsafeBufferPointer<UInt8>) {
        for s in targets() { s.tapOutput(bytes) }
    }

    fileprivate func deliverResize(columns: Int, rows: Int) {
        for s in targets() { s.tapResized(columns: columns, rows: rows) }
    }

    nonisolated private static let outputCB: ghostty_surface_output_cb = { userdata, bytes, len in
        guard let userdata, let bytes, len > 0 else { return }
        Unmanaged<OutputTapHub>.fromOpaque(userdata).takeUnretainedValue()
            .deliver(UnsafeBufferPointer(start: bytes, count: Int(len)))
    }

    nonisolated private static let resizeCB: ghostty_surface_resize_cb = { userdata, columns, rows in
        guard let userdata else { return }
        Unmanaged<OutputTapHub>.fromOpaque(userdata).takeUnretainedValue()
            .deliverResize(columns: Int(columns), rows: Int(rows))
    }
}
