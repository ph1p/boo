import Foundation

/// The closed tabs, panes and workspaces of one window, newest last.
///
/// An entry holds what "Undo Close" needs: the `fallback` (reopen a fresh
/// shell in the old folder) and, for a short time after the close, the `live`
/// payload that is still running. When the time is up the store destroys the
/// live payload and keeps the fallback.
@MainActor
final class ClosedItemStore<Live> {
    struct Entry {
        let id: UUID
        var fallback: MainWindowController.ClosedItem?
        var live: Live?
        /// When `live` is destroyed; nil without one.
        var deadline: Date?
        /// The panes the entry reopens into or beside. An entry moves with
        /// these panes when their workspace goes to another window.
        var paneIDs: Set<UUID>
    }

    private(set) var entries: [Entry] = []
    let capacity = 20
    /// Ends a live payload that will not be restored.
    var destroy: (Live) -> Void = { _ in }

    private let now: () -> Date
    private var timerGeneration = 0

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Adds an entry. `live` is kept for `lifetime` seconds and destroyed at
    /// once when `lifetime` is 0. Returns nil when nothing is left to undo.
    @discardableResult
    func push(
        fallback: MainWindowController.ClosedItem?, live: Live? = nil, lifetime: TimeInterval = 0,
        paneIDs: Set<UUID> = []
    ) -> UUID? {
        var kept = live
        if let live, lifetime <= 0 {
            destroy(live)
            kept = nil
        }
        guard fallback != nil || kept != nil else { return nil }
        let entry = Entry(
            id: UUID(), fallback: fallback, live: kept,
            deadline: kept == nil ? nil : now().addingTimeInterval(lifetime), paneIDs: paneIDs)
        append([entry])
        return entry.id
    }

    /// The newest entry. Its live payload now belongs to the caller.
    func popLast() -> Entry? {
        expire()
        let entry = entries.popLast()
        schedule()
        return entry
    }

    /// The entry with `id`. Its live payload now belongs to the caller.
    func take(id: UUID) -> Entry? {
        expire()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        schedule()
        return entry
    }

    /// Destroys the live payloads whose time is up. Their entries stay as
    /// long as they have a fallback.
    func expire() {
        let date = now()
        for entry in entries {
            if let deadline = entry.deadline, deadline <= date { dropLive(id: entry.id) }
        }
        schedule()
    }

    /// Destroys the live payload of one entry, for example when its shell exits.
    func dropLive(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Out of the list before `destroy` runs: `destroy` can call back in.
        let live = entries[index].live
        entries[index].live = nil
        entries[index].deadline = nil
        if entries[index].fallback == nil { entries.remove(at: index) }
        if let live { destroy(live) }
        schedule()
    }

    /// The window closes: nothing can be undone any more.
    func discardAll() {
        let old = entries
        entries = []
        timerGeneration += 1
        for entry in old {
            if let live = entry.live { destroy(live) }
        }
    }

    /// Removes and returns the entries that pass `matches`, oldest first.
    func extract(where matches: (Entry) -> Bool) -> [Entry] {
        let taken = entries.filter(matches)
        guard !taken.isEmpty else { return [] }
        let ids = Set(taken.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        schedule()
        return taken
    }

    /// Adds entries from another store, with their deadlines.
    func append(_ added: [Entry]) {
        entries.append(contentsOf: added)
        while entries.count > capacity {
            if let live = entries.removeFirst().live { destroy(live) }
        }
        schedule()
    }

    /// One timer, set to the earliest deadline.
    private func schedule() {
        timerGeneration += 1
        guard let next = entries.compactMap(\.deadline).min() else { return }
        let generation = timerGeneration
        let delay = max(0.05, next.timeIntervalSince(now()))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timerGeneration == generation else { return }
                self.expire()
            }
        }
    }
}
