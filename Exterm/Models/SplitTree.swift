import Foundation

/// Binary tree for split pane layout.
/// Each leaf holds a terminal session identifier.
indirect enum SplitTree {
    case leaf(id: UUID)
    case split(direction: SplitDirection, first: SplitTree, second: SplitTree, ratio: CGFloat)

    enum SplitDirection {
        case horizontal // side by side
        case vertical   // top and bottom
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
            return (self, UUID()) // no match
        }
    }

    /// Remove a leaf, returning the sibling tree (or nil if this is the last leaf).
    func removing(leafID: UUID) -> SplitTree? {
        switch self {
        case .leaf(let id):
            return id == leafID ? nil : self

        case .split(_, let first, let second, _):
            if case .leaf(let id) = first, id == leafID {
                return second
            }
            if case .leaf(let id) = second, id == leafID {
                return first
            }

            // Try removing from first subtree
            if first.containsLeaf(leafID) {
                if let newFirst = first.removing(leafID: leafID) {
                    return .split(direction: direction!, first: newFirst, second: second, ratio: ratio!)
                }
                // first collapsed to nil — return second
                return second
            }
            // Try removing from second subtree
            if second.containsLeaf(leafID) {
                if let newSecond = second.removing(leafID: leafID) {
                    return .split(direction: direction!, first: first, second: newSecond, ratio: ratio!)
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

    private var direction: SplitDirection? {
        if case .split(let d, _, _, _) = self { return d }
        return nil
    }

    private var ratio: CGFloat? {
        if case .split(_, _, _, let r) = self { return r }
        return nil
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
