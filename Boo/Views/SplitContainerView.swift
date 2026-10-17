import Cocoa

@MainActor protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView
}

/// Renders a `SplitTree` as nested `ThemedSplitView`s.
///
/// Updates reconcile the existing hierarchy in place: split views and pane
/// views whose position survives stay attached, so splitting or closing one
/// pane only re-parents the panes next to it instead of detaching every
/// live terminal surface.
///
/// Each split view lays out its two children from its stored `ratio`, so
/// window, sidebar and fullscreen resizes keep proportions exactly. Ratios
/// change only through the tree or a user dragging a divider.
class SplitContainerView: NSView, NSSplitViewDelegate {
    weak var splitDelegate: SplitContainerDelegate?

    /// Called once a divider drag ends (or a divider is double-clicked) with the updated tree.
    var onRatioChanged: ((SplitTree) -> Void)?

    private var currentView: NSView?
    private var currentTree: SplitTree?
    /// Tree currently on screen, including in-progress divider drags.
    var renderedTree: SplitTree? { currentTree }
    /// Minimum dimension (width or height) for terminal panes in splits.
    let minPaneDimension: CGFloat = 80
    /// Divider positions within this distance of the balanced position snap to it.
    private let snapDistance: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Transparent: each PaneView is its own rounded island and paints its own
        // background, so the window backdrop shows through the gaps between them.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tree: SplitTree) {
        // Re-parenting views resizes split views that still have us as their
        // delegate; their resize notifications are us, not the user.
        isRebuilding = true
        defer { isRebuilding = false }

        let previousSplitViews = currentView.map(Self.splitViews(in:)) ?? []
        currentTree = tree
        let root = reconcile(currentView, with: tree)
        if root !== currentView || root.superview !== self {
            root.frame = bounds
            root.autoresizingMask = [.width, .height]
            if let old = currentView, old.superview === self, old !== root {
                replaceSubview(old, with: root)
            } else {
                addSubview(root)
            }
            currentView = root
        }
        // Workspace switches must never leave stale panes behind.
        for subview in subviews where subview !== root {
            subview.removeFromSuperview()
        }
        for orphan in previousSplitViews where !orphan.isDescendant(of: self) {
            orphan.delegate = nil
        }
        if root.frame != bounds { root.frame = bounds }
        layoutByRatio(root)
    }

    /// True while `update(tree:)` re-establishes the hierarchy.
    private var isRebuilding = false

    // MARK: - Reconcile

    /// View for `tree`, reusing `existing` when it is a split view on the same
    /// axis (its children are reconciled position by position). Pane views
    /// come from the delegate, which caches them per pane ID.
    private func reconcile(_ existing: NSView?, with tree: SplitTree) -> NSView {
        switch tree {
        case .leaf(let id):
            guard let delegate = splitDelegate else { return NSView() }
            return delegate.splitContainer(self, paneViewFor: id)

        case .split(let direction, let first, let second, let ratio):
            let splitView: ThemedSplitView
            if let reused = existing as? ThemedSplitView, reused.isVertical == (direction == .horizontal) {
                splitView = reused
            } else {
                splitView = makeSplitView(direction: direction)
                // Start at the replaced view's size so the first layout pass is final.
                splitView.frame = existing?.frame ?? bounds
            }
            splitView.ratio = ratio
            let oldChildren = splitView.subviews
            let a = reconcile(oldChildren.count > 0 ? oldChildren[0] : nil, with: first)
            let b = reconcile(oldChildren.count > 1 ? oldChildren[1] : nil, with: second)
            if splitView.subviews.count != 2 || splitView.subviews[0] !== a || splitView.subviews[1] !== b {
                // Assigning `subviews` keeps views present in both arrays attached.
                splitView.subviews = [a, b]
            }
            return splitView
        }
    }

    private func makeSplitView(direction: SplitTree.SplitDirection) -> ThemedSplitView {
        let splitView = ThemedSplitView()
        splitView.isVertical = (direction == .horizontal)
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.onDividerDoubleClick = { [weak self, weak splitView] in
            guard let self, let splitView else { return }
            self.balanceDivider(of: splitView)
        }
        splitView.onDividerDragEnded = { [weak self] in
            guard let self, let tree = self.currentTree else { return }
            self.onRatioChanged?(tree)
        }
        return splitView
    }

    private static func splitViews(in view: NSView) -> [ThemedSplitView] {
        guard let splitView = view as? ThemedSplitView else { return [] }
        return [splitView] + splitView.subviews.flatMap(splitViews(in:))
    }

    // MARK: - Layout

    /// Lay out `view` and every split view below it from the stored ratios.
    private func layoutByRatio(_ view: NSView) {
        guard let splitView = view as? ThemedSplitView else { return }
        layoutChildren(of: splitView)
        for child in splitView.subviews { layoutByRatio(child) }
    }

    /// Position the two children of `splitView` from its ratio, keeping each
    /// at least `minPaneDimension` (or half the space when that doesn't fit).
    private func layoutChildren(of splitView: ThemedSplitView) {
        guard splitView.subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let bounds = splitView.bounds
        let thickness = splitView.dividerThickness
        let length = splitView.isVertical ? bounds.width : bounds.height
        let available = max(0, length - thickness)
        let minimum = min(minPaneDimension, available / 2)
        let firstLength = min(max((available * splitView.ratio).rounded(), minimum), available - minimum)
        let secondLength = available - firstLength
        let first: CGRect
        let second: CGRect
        if splitView.isVertical {
            first = CGRect(x: 0, y: 0, width: firstLength, height: bounds.height)
            second = CGRect(x: firstLength + thickness, y: 0, width: secondLength, height: bounds.height)
        } else {
            // NSSplitView is flipped: the first subview is the top one.
            first = CGRect(x: 0, y: 0, width: bounds.width, height: firstLength)
            second = CGRect(x: 0, y: firstLength + thickness, width: bounds.width, height: secondLength)
        }
        if splitView.subviews[0].frame != first { splitView.subviews[0].frame = first }
        if splitView.subviews[1].frame != second { splitView.subviews[1].frame = second }
    }

    /// Double-clicking a divider gives every pane along it the same size.
    private func balanceDivider(of splitView: ThemedSplitView) {
        guard let tree = currentTree, let root = currentView,
            let ratio = node(for: splitView, in: tree, rootView: root)?.balancedRatio
        else { return }
        splitView.ratio = ratio
        layoutByRatio(splitView)
        let updated = updatingRatio(in: tree, newRatio: ratio, matchingSplitView: splitView, rootView: root)
        guard updated != tree else { return }
        currentTree = updated
        onRatioChanged?(updated)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let themed = splitView as? ThemedSplitView else {
            splitView.adjustSubviews()
            return
        }
        layoutChildren(of: themed)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMinimumPosition + minPaneDimension
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMaximumPosition - minPaneDimension
    }

    /// Snap a dragged divider to the position that makes the panes along it equal.
    func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let themed = splitView as? ThemedSplitView, let tree = currentTree, let root = currentView,
            let balanced = node(for: themed, in: tree, rootView: root)?.balancedRatio
        else { return proposedPosition }
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let target = ((length - splitView.dividerThickness) * balanced).rounded()
        return abs(proposedPosition - target) <= snapDistance ? target : proposedPosition
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // This fires for every subview resize: window and sidebar resizes and our
        // own layout passes included. Only a divider the user is dragging changes
        // the ratio; everything else is laid out from the stored ratios.
        guard let splitView = notification.object as? ThemedSplitView,
            splitView.isDraggingDivider, !isRebuilding,
            splitView.subviews.count >= 2, splitView.isDescendant(of: self),
            let rootView = currentView, let tree = currentTree
        else { return }

        let firstSize = splitView.isVertical ? splitView.subviews[0].frame.width : splitView.subviews[0].frame.height
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = length - splitView.dividerThickness
        guard available > 0 else { return }
        let newRatio = min(max(firstSize / available, 0.01), 0.99)
        splitView.ratio = newRatio
        // Nested splits follow their own ratios while the outer divider moves.
        for child in splitView.subviews { layoutByRatio(child) }

        // The tree is reported once, when the drag ends.
        currentTree = updatingRatio(in: tree, newRatio: newRatio, matchingSplitView: splitView, rootView: rootView)
    }

    // MARK: - Tree ↔ view mapping

    /// Walk the tree and view hierarchy in parallel; update the ratio of the split node
    /// whose view identity matches `splitView`.
    private func updatingRatio(
        in tree: SplitTree,
        newRatio: CGFloat,
        matchingSplitView splitView: NSSplitView,
        rootView: NSView
    ) -> SplitTree {
        switch tree {
        case .leaf:
            return tree
        case .split(let dir, let first, let second, let ratio):
            guard let sv = rootView as? NSSplitView, sv.subviews.count >= 2 else { return tree }
            if sv === splitView {
                return .split(direction: dir, first: first, second: second, ratio: newRatio)
            }
            let newFirst = updatingRatio(
                in: first, newRatio: newRatio, matchingSplitView: splitView, rootView: sv.subviews[0])
            let newSecond = updatingRatio(
                in: second, newRatio: newRatio, matchingSplitView: splitView, rootView: sv.subviews[1])
            return .split(direction: dir, first: newFirst, second: newSecond, ratio: ratio)
        }
    }

    /// Subtree rendered by `splitView`.
    private func node(for splitView: NSSplitView, in tree: SplitTree, rootView: NSView) -> SplitTree? {
        guard case .split(_, let first, let second, _) = tree,
            let sv = rootView as? NSSplitView, sv.subviews.count >= 2
        else { return nil }
        if sv === splitView { return tree }
        return node(for: splitView, in: first, rootView: sv.subviews[0])
            ?? node(for: splitView, in: second, rootView: sv.subviews[1])
    }
}
