import Foundation

/// Pure-logic helpers for sidebar tab ordering.
///
/// When tabs appear / disappear across contexts (local ↔ remote), the saved
/// order must not lose positions for currently-hidden tabs, and tabs that have
/// never been saved should land in a stable position rather than always jumping
/// to the end.
enum SidebarTabOrdering {

    /// Sort `tabs` according to `savedOrder`, using each tab's array index as a
    /// stable fallback for IDs that aren't in the saved list.
    static func applied(tabs: [SidebarTab], savedOrder: [String]) -> [SidebarTab] {
        let orderMap = Dictionary(
            uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
        let registrationIndex = Dictionary(
            uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })

        return tabs.sorted { a, b in
            let ia = orderMap[a.id.id]
            let ib = orderMap[b.id.id]

            switch (ia, ib) {
            case let (.some(ai), .some(bi)):
                return ai < bi
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return (registrationIndex[a.id] ?? 0) < (registrationIndex[b.id] ?? 0)
            }
        }
    }

    /// Merge a new visible ordering into the full saved order, keeping hidden
    /// tab IDs at their original saved positions.
    ///
    /// Hidden tabs stay pinned at the indices they occupied in `saved`.
    /// Visible tabs fill the remaining slots in their new order.
    ///
    /// Example: saved = `["A", "B", "C", "D"]`, visible (reordered) = `["C", "A"]`
    /// → hidden = B (index 1), D (index 3) stay put
    /// → visible C, A fill indices 0 and 2
    /// → result = `["C", "B", "A", "D"]`
    static func mergeOrder(saved: [String], visible: [String]) -> [String] {
        let visibleSet = Set(visible)

        // Collect hidden IDs with their original indices.
        var hiddenSlots: [(index: Int, id: String)] = []
        for (i, id) in saved.enumerated() where !visibleSet.contains(id) {
            hiddenSlots.append((i, id))
        }

        // Total length = hidden (kept) + visible (new, may include IDs not in saved)
        let totalCount = hiddenSlots.count + visible.count

        // Place hidden tabs at their original indices (clamped to new length).
        var result = [String?](repeating: nil, count: totalCount)
        for slot in hiddenSlots {
            let idx = min(slot.index, totalCount - 1)
            // Find nearest free position at or after the original index.
            if result[idx] == nil {
                result[idx] = slot.id
            } else {
                // Slot taken — scan forward then wrap.
                var placed = false
                for j in (idx + 1)..<totalCount where result[j] == nil {
                    result[j] = slot.id
                    placed = true
                    break
                }
                if !placed {
                    for j in 0..<idx where result[j] == nil {
                        result[j] = slot.id
                        break
                    }
                }
            }
        }

        // Fill remaining nil slots with visible tabs in their new order.
        var visibleIter = visible.makeIterator()
        for i in 0..<totalCount where result[i] == nil {
            result[i] = visibleIter.next()
        }

        return result.compactMap { $0 }
    }
}
