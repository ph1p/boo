import Foundation

/// Finder-style selection over the tree's visible rows. Callers pass the current row
/// order (visible paths, top to bottom) since it changes with every expand/filter.
@MainActor
final class FileTreeSelection: ObservableObject {
    @Published private(set) var selected: Set<String> = []
    /// Keyboard focus row — the end that moves on ⇧-arrow.
    @Published private(set) var cursor: String?
    /// Fixed end of a ⇧ range.
    private var anchor: String?

    enum ClickKind { case plain, toggle, extend }

    func contains(_ path: String) -> Bool { selected.contains(path) }

    /// Apply a click. `.toggle` is ⌘-click, `.extend` ⇧-click.
    func click(_ path: String, kind: ClickKind, order: [String]) {
        switch kind {
        case .plain:
            select(path)
        case .toggle:
            if selected.contains(path) {
                selected.remove(path)
                if cursor == path { cursor = selected.first }
            } else {
                selected.insert(path)
                cursor = path
            }
            anchor = cursor
        case .extend:
            extend(to: path, order: order)
        }
    }

    /// Replace the selection with one row.
    func select(_ path: String) {
        selected = [path]
        cursor = path
        anchor = path
    }

    /// Move the cursor `delta` rows; with `extend`, grow the range from the anchor.
    func move(by delta: Int, order: [String], extend: Bool) {
        guard !order.isEmpty else { return }
        let target: String
        if let cursor, let i = order.firstIndex(of: cursor) {
            target = order[max(0, min(order.count - 1, i + delta))]
        } else {
            target = delta >= 0 ? order[0] : order[order.count - 1]
        }
        if extend { self.extend(to: target, order: order) } else { select(target) }
    }

    func selectAll(order: [String]) {
        selected = Set(order)
        if cursor == nil { cursor = order.first }
        anchor = cursor
    }

    func clear() {
        selected = []
        cursor = nil
        anchor = nil
    }

    /// Drop rows that vanished (deleted, collapsed away, filtered out).
    func prune(visible order: [String]) {
        let visible = Set(order)
        let kept = selected.intersection(visible)
        if kept != selected { selected = kept }
        if let c = cursor, !visible.contains(c) { cursor = nil }
        if let a = anchor, !visible.contains(a) { anchor = cursor }
    }

    /// Selected paths in row order — the order actions should run in.
    func ordered(in order: [String]) -> [String] {
        order.filter { selected.contains($0) }
    }

    private func extend(to path: String, order: [String]) {
        guard let from = anchor ?? cursor, let a = order.firstIndex(of: from),
            let b = order.firstIndex(of: path)
        else {
            select(path)
            return
        }
        selected = Set(order[min(a, b)...max(a, b)])
        anchor = from
        cursor = path
    }
}
