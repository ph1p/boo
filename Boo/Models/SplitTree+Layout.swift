import CoreGraphics
import Foundation

/// Screen direction for moving focus, resizing and swapping panes.
enum PaneDirection: CaseIterable {
    case left, right, up, down

    /// Split axis a divider must lie on to move in this direction.
    var axis: SplitTree.SplitDirection {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// Whether this direction grows coordinates (right, down in a top-left origin).
    var isForward: Bool { self == .right || self == .down }
}

extension SplitTree {
    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, let first, let second, _): return first.leafCount + second.leafCount
        }
    }

    func containsLeafID(_ leafID: UUID) -> Bool {
        switch self {
        case .leaf(let id): return id == leafID
        case .split(_, let first, let second, _):
            return first.containsLeafID(leafID) || second.containsLeafID(leafID)
        }
    }

    /// Number of panes laid out side by side along `axis`: splits on that axis
    /// add up, splits across it take the larger side.
    func weight(along axis: SplitDirection) -> Int {
        switch self {
        case .leaf: return 1
        case .split(let direction, let first, let second, _):
            let a = first.weight(along: axis)
            let b = second.weight(along: axis)
            return direction == axis ? a + b : max(a, b)
        }
    }

    /// Ratio that gives every pane along this split's axis the same size.
    /// Nil for a leaf.
    var balancedRatio: CGFloat? {
        guard case .split(let direction, let first, let second, _) = self else { return nil }
        let a = CGFloat(first.weight(along: direction))
        let b = CGFloat(second.weight(along: direction))
        return a / (a + b)
    }

    /// Every pane the same size along each axis (a 3-way row gets thirds,
    /// not half + two quarters).
    func equalized() -> SplitTree {
        switch self {
        case .leaf: return self
        case .split(let direction, let first, let second, _):
            return .split(
                direction: direction, first: first.equalized(), second: second.equalized(),
                ratio: balancedRatio ?? 0.5)
        }
    }

    /// Exchange the positions of two leaves.
    func swappingLeaves(_ a: UUID, _ b: UUID) -> SplitTree {
        guard a != b, containsLeafID(a), containsLeafID(b) else { return self }
        return remappingLeafIDs([a: b, b: a])
    }

    /// Sizes of the two children of a split laid out in `size`; dividers are
    /// ignored (the view layer subtracts them).
    static func childSizes(of size: CGSize, direction: SplitDirection, ratio: CGFloat) -> (CGSize, CGSize) {
        switch direction {
        case .horizontal:
            let w = size.width * ratio
            return (CGSize(width: w, height: size.height), CGSize(width: size.width - w, height: size.height))
        case .vertical:
            let h = size.height * ratio
            return (CGSize(width: size.width, height: h), CGSize(width: size.width, height: size.height - h))
        }
    }

    /// Frame of every leaf inside `rect`, origin top-left (`first` of a
    /// vertical split is the top pane).
    func leafFrames(in rect: CGRect) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let direction, let first, let second, let ratio):
            let (a, _) = Self.childSizes(of: rect.size, direction: direction, ratio: ratio)
            let firstRect: CGRect
            let secondRect: CGRect
            switch direction {
            case .horizontal:
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: a.width, height: rect.height)
                secondRect = CGRect(
                    x: rect.minX + a.width, y: rect.minY, width: rect.width - a.width, height: rect.height)
            case .vertical:
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: a.height)
                secondRect = CGRect(
                    x: rect.minX, y: rect.minY + a.height, width: rect.width, height: rect.height - a.height)
            }
            return first.leafFrames(in: firstRect).merging(second.leafFrames(in: secondRect)) { a, _ in a }
        }
    }

    /// Pane next to `leafID` in `direction`, nil at the edge. Among several
    /// touching panes, the one level with the source's centre wins, then the
    /// one sharing the longest edge.
    func neighbor(
        of leafID: UUID, toward direction: PaneDirection, in size: CGSize = CGSize(width: 1000, height: 1000)
    ) -> UUID? {
        let frames = leafFrames(in: CGRect(origin: .zero, size: size))
        guard let source = frames[leafID] else { return nil }
        let epsilon: CGFloat = 0.5
        var best: (id: UUID, centred: Bool, overlap: CGFloat)?
        for (id, frame) in frames where id != leafID {
            let touches: Bool
            let overlap: CGFloat
            let centred: Bool
            switch direction {
            case .left, .right:
                touches =
                    direction == .left
                    ? abs(frame.maxX - source.minX) < epsilon : abs(frame.minX - source.maxX) < epsilon
                overlap = min(frame.maxY, source.maxY) - max(frame.minY, source.minY)
                centred = frame.minY <= source.midY && source.midY <= frame.maxY
            case .up, .down:
                touches =
                    direction == .up
                    ? abs(frame.maxY - source.minY) < epsilon : abs(frame.minY - source.maxY) < epsilon
                overlap = min(frame.maxX, source.maxX) - max(frame.minX, source.minX)
                centred = frame.minX <= source.midX && source.midX <= frame.maxX
            }
            guard touches, overlap > epsilon else { continue }
            if let current = best {
                if current.centred && !centred { continue }
                if current.centred == centred && current.overlap >= overlap { continue }
            }
            best = (id, centred, overlap)
        }
        return best?.id
    }

    /// Move the divider nearest to `leafID` on `direction`'s axis by `amount`
    /// points toward `direction`, keeping both sides at least `minimum` wide.
    /// Unchanged when no ancestor split lies on that axis.
    func resizing(
        leafID: UUID, toward direction: PaneDirection, by amount: CGFloat, in size: CGSize,
        minimum: CGFloat = 0
    ) -> SplitTree {
        resized(leafID: leafID, toward: direction, by: amount, in: size, minimum: minimum) ?? self
    }

    private func resized(
        leafID: UUID, toward direction: PaneDirection, by amount: CGFloat, in size: CGSize, minimum: CGFloat
    ) -> SplitTree? {
        guard case .split(let dir, let first, let second, let ratio) = self, containsLeafID(leafID) else {
            return nil
        }
        let inFirst = first.containsLeafID(leafID)
        let (firstSize, secondSize) = Self.childSizes(of: size, direction: dir, ratio: ratio)
        // The innermost matching split owns the divider next to the pane.
        if let inner = (inFirst ? first : second).resized(
            leafID: leafID, toward: direction, by: amount, in: inFirst ? firstSize : secondSize, minimum: minimum)
        {
            return inFirst
                ? .split(direction: dir, first: inner, second: second, ratio: ratio)
                : .split(direction: dir, first: first, second: inner, ratio: ratio)
        }
        guard dir == direction.axis else { return nil }
        let length = dir == .horizontal ? size.width : size.height
        guard length > 0 else { return self }
        let delta = (direction.isForward ? amount : -amount) / length
        let floor = min(minimum / length, 0.5)
        let newRatio = min(max(ratio + delta, floor), 1 - floor)
        return .split(direction: dir, first: first, second: second, ratio: newRatio)
    }
}
