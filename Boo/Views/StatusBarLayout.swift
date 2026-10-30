import CoreGraphics

/// Pure layout rules for the status bar: which side each segment sits on, in
/// what order, and which ones are dropped when the bar is too narrow. Kept free
/// of AppKit so the rules can be tested without drawing.
enum StatusBarLayout {
    /// Segment IDs per side, in visual left-to-right order.
    struct Arrangement: Equatable {
        var left: [String]
        var right: [String]
    }

    /// Merges the user's saved order into the built-in one. Saved IDs keep their
    /// side and order; IDs the user never placed (new plugins, IPC segments) go
    /// on their default side, before the first saved neighbour that comes after
    /// them in the built-in order.
    static func arrange(defaults: Arrangement, leftOrder: [String], rightOrder: [String]) -> Arrangement {
        let all = defaults.left + defaults.right
        var rank: [String: Int] = [:]
        for (i, id) in all.enumerated() where rank[id] == nil { rank[id] = i }

        var seen = Set<String>()
        func known(_ ids: [String]) -> [String] {
            ids.filter { rank[$0] != nil && seen.insert($0).inserted }
        }
        var result = Arrangement(left: known(leftOrder), right: known(rightOrder))

        func insert(_ id: String, into list: inout [String]) {
            let r = rank[id] ?? Int.max
            let index = list.firstIndex { (rank[$0] ?? Int.max) > r } ?? list.count
            list.insert(id, at: index)
        }
        for id in defaults.left where seen.insert(id).inserted { insert(id, into: &result.left) }
        for id in defaults.right where seen.insert(id).inserted { insert(id, into: &result.right) }
        return result
    }

    /// Moves `id` to the other side: onto the inner end of the right group, or
    /// the outer end of the left group, where it is easiest to spot.
    static func moving(_ id: String, toLeft: Bool, in arrangement: Arrangement) -> Arrangement {
        var result = arrangement
        result.left.removeAll { $0 == id }
        result.right.removeAll { $0 == id }
        if toLeft {
            result.left.append(id)
        } else {
            result.right.insert(id, at: 0)
        }
        return result
    }

    /// Moves `id` by `offset` places within its side; clamps at either end.
    static func moving(_ id: String, by offset: Int, in arrangement: Arrangement) -> Arrangement {
        func shift(_ list: inout [String]) -> Bool {
            guard let i = list.firstIndex(of: id) else { return false }
            list.remove(at: i)
            list.insert(id, at: max(0, min(list.count, i + offset)))
            return true
        }
        var result = arrangement
        if !shift(&result.left) { _ = shift(&result.right) }
        return result
    }

    /// A segment ready to place: its width on the side it sits on, and how
    /// readily it gives way when space runs out.
    struct Measured {
        let id: String
        let width: CGFloat
        let collapsePriority: Int
    }

    /// IDs to leave out so both sides fit `available`, with `separator` between
    /// neighbours on the left and at least `minGap` between the two sides.
    /// Highest collapse priority goes first; on a tie, the one furthest from
    /// its bar edge. Collapse priority 0 never goes.
    static func overflow(
        left: [Measured], right: [Measured], available: CGFloat, separator: CGFloat, minGap: CGFloat
    ) -> Set<String> {
        var dropped = Set<String>()
        func required() -> CGFloat {
            let l = left.filter { !dropped.contains($0.id) }
            let r = right.filter { !dropped.contains($0.id) }
            let lw = l.reduce(0) { $0 + $1.width } + CGFloat(max(0, l.count - 1)) * separator
            let rw = r.reduce(0) { $0 + $1.width }
            return lw + rw + (l.isEmpty || r.isEmpty ? 0 : minGap)
        }
        // Distance from the edge: the left group grows rightwards, the right
        // group leftwards, so later-left and earlier-right are the innermost.
        let candidates =
            left.enumerated().map { (segment: $1, depth: $0) }
            + right.reversed().enumerated().map { (segment: $1, depth: $0) }
        while required() > available {
            let victim =
                candidates
                .filter { !dropped.contains($0.segment.id) && $0.segment.collapsePriority > 0 }
                .max { a, b in
                    a.segment.collapsePriority != b.segment.collapsePriority
                        ? a.segment.collapsePriority < b.segment.collapsePriority
                        : a.depth < b.depth
                }
            guard let victim else { break }
            dropped.insert(victim.segment.id)
        }
        return dropped
    }
}
