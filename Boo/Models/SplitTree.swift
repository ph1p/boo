import Foundation

/// Binary tree for split pane layout.
/// Each leaf holds a terminal session identifier.
indirect enum SplitTree {
    case leaf(id: UUID)
    case split(direction: SplitDirection, first: SplitTree, second: SplitTree, ratio: CGFloat)

    enum SplitDirection {
        case horizontal  // side by side
        case vertical  // top and bottom
    }

    /// Split the leaf with the given ID, returning a new tree.
    func splitting(leafID: UUID, direction: SplitDirection) -> (SplitTree, UUID) {
        switch self {
        case .leaf(let id) where id == leafID:
            let newID = UUID()
            let newTree = SplitTree.split(
                direction: direction,
                first: .leaf(id: id),
                second: .leaf(id: newID),
                ratio: 0.5
            )
            return (newTree, newID)

        case .split(let dir, let first, let second, let ratio):
            let (newFirst, newID1) = first.splitting(leafID: leafID, direction: direction)
            if newFirst != first {
                return (.split(direction: dir, first: newFirst, second: second, ratio: ratio), newID1)
            }
            let (newSecond, newID2) = second.splitting(leafID: leafID, direction: direction)
            return (.split(direction: dir, first: first, second: newSecond, ratio: ratio), newID2)

        default:
            return (self, UUID())  // no match
        }
    }

    /// Remove a leaf, returning the sibling tree (or nil if this is the last leaf).
    func removing(leafID: UUID) -> SplitTree? {
        switch self {
        case .leaf(let id):
            return id == leafID ? nil : self

        case .split(let dir, let first, let second, let r):
            if case .leaf(let id) = first, id == leafID {
                return second
            }
            if case .leaf(let id) = second, id == leafID {
                return first
            }

            // Try removing from first subtree
            if first.containsLeaf(leafID) {
                if let newFirst = first.removing(leafID: leafID) {
                    return .split(direction: dir, first: newFirst, second: second, ratio: r)
                }
                // first collapsed to nil — return second
                return second
            }
            // Try removing from second subtree
            if second.containsLeaf(leafID) {
                if let newSecond = second.removing(leafID: leafID) {
                    return .split(direction: dir, first: first, second: newSecond, ratio: r)
                }
                return first
            }
            return self
        }
    }

    private func containsLeaf(_ leafID: UUID) -> Bool {
        leafIDs.contains(leafID)
    }

    /// All leaf IDs in order
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, let first, let second, _):
            return first.leafIDs + second.leafIDs
        }
    }

    /// Find the closest sibling leaf ID for a given leaf.
    /// Returns the nearest leaf in the sibling subtree of the direct parent split.
    func siblingLeafID(of leafID: UUID) -> UUID? {
        switch self {
        case .leaf:
            return nil
        case .split(_, let first, let second, _):
            // If target is a direct child, return the closest leaf from the other side
            if case .leaf(let id) = first, id == leafID {
                return second.leafIDs.first
            }
            if case .leaf(let id) = second, id == leafID {
                return first.leafIDs.last
            }
            // Recurse: check if the leaf is deeper in first or second
            if first.containsLeaf(leafID) {
                // Prefer sibling within the same subtree; fall back to nearest in other subtree
                return first.siblingLeafID(of: leafID) ?? second.leafIDs.first
            }
            if second.containsLeaf(leafID) {
                return second.siblingLeafID(of: leafID) ?? first.leafIDs.last
            }
            return nil
        }
    }

    func remappingLeafIDs(_ mapping: [UUID: UUID]) -> SplitTree {
        switch self {
        case .leaf(let id):
            return .leaf(id: mapping[id] ?? id)
        case .split(let direction, let first, let second, let ratio):
            return .split(
                direction: direction,
                first: first.remappingLeafIDs(mapping),
                second: second.remappingLeafIDs(mapping),
                ratio: ratio
            )
        }
    }

    private var direction: SplitDirection? {
        if case .split(let d, _, _, _) = self { return d }
        return nil
    }

    private var ratio: CGFloat? {
        if case .split(_, _, _, let r) = self { return r }
        return nil
    }

    /// After splitting a leaf, the new pane appears as the second child.
    /// For left/top edge drops we need the new pane first. This swaps
    /// the children of the parent split containing the given leaf.
    func swappingChildrenAtParent(of leafID: UUID) -> SplitTree {
        switch self {
        case .leaf:
            return self
        case .split(let dir, let first, let second, let ratio):
            // If the target leaf is a direct child, swap children
            if case .leaf(let id) = first, id == leafID {
                return .split(direction: dir, first: second, second: first, ratio: 1.0 - ratio)
            }
            if case .leaf(let id) = second, id == leafID {
                return .split(direction: dir, first: second, second: first, ratio: 1.0 - ratio)
            }
            // Recurse
            let newFirst = first.swappingChildrenAtParent(of: leafID)
            if newFirst != first {
                return .split(direction: dir, first: newFirst, second: second, ratio: ratio)
            }
            let newSecond = second.swappingChildrenAtParent(of: leafID)
            return .split(direction: dir, first: first, second: newSecond, ratio: ratio)
        }
    }
}

// MARK: - Codable

extension SplitTree: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, direction, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "leaf" {
            let id = try c.decode(UUID.self, forKey: .id)
            self = .leaf(id: id)
        } else {
            let dirStr = try c.decode(String.self, forKey: .direction)
            let dir: SplitDirection = dirStr == "vertical" ? .vertical : .horizontal
            let first = try c.decode(SplitTree.self, forKey: .first)
            let second = try c.decode(SplitTree.self, forKey: .second)
            let ratio = try c.decode(CGFloat.self, forKey: .ratio)
            self = .split(direction: dir, first: first, second: second, ratio: ratio)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode("leaf", forKey: .type)
            try c.encode(id, forKey: .id)
        case .split(let direction, let first, let second, let ratio):
            try c.encode("split", forKey: .type)
            try c.encode(direction == .vertical ? "vertical" : "horizontal", forKey: .direction)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
            try c.encode(ratio, forKey: .ratio)
        }
    }
}

extension SplitTree: Equatable {
    static func == (lhs: SplitTree, rhs: SplitTree) -> Bool {
        switch (lhs, rhs) {
        case (.leaf(let a), .leaf(let b)):
            return a == b
        case (.split(let d1, let f1, let s1, let r1), .split(let d2, let f2, let s2, let r2)):
            return d1 == d2 && f1 == f2 && s1 == s2 && r1 == r2
        default:
            return false
        }
    }
}
