import Cocoa

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView
}

class SplitContainerView: NSView, NSSplitViewDelegate {
    weak var splitDelegate: SplitContainerDelegate?

    /// Called whenever the user drags a divider, with the updated tree.
    var onRatioChanged: ((SplitTree) -> Void)?

    private var currentView: NSView?
    private var currentTree: SplitTree?
    /// Minimum dimension (width or height) for terminal panes in splits.
    private let minPaneDimension: CGFloat = 80

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tree: SplitTree) {
        currentTree = tree

        // Remove any existing hierarchy so workspace switches cannot leave stale panes behind.
        for subview in subviews {
            subview.removeFromSuperview()
        }
        currentView = nil

        let view = buildView(from: tree)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        currentView = view
        needsLayout = true
        layoutSubtreeIfNeeded()

        // Defer split position setting until after layout
        DispatchQueue.main.async { [weak self] in
            self?.applySplitPositions(view: view, tree: tree)
        }
    }

    private func buildView(from tree: SplitTree) -> NSView {
        switch tree {
        case .leaf(let id):
            guard let delegate = splitDelegate else { return NSView() }
            let pv = delegate.splitContainer(self, paneViewFor: id)
            return pv

        case .split(let direction, let first, let second, _):
            let splitView = ThemedSplitView()
            splitView.isVertical = (direction == .horizontal)
            splitView.dividerStyle = .thin
            splitView.delegate = self

            let firstView = buildView(from: first)
            let secondView = buildView(from: second)

            splitView.addSubview(firstView)
            splitView.addSubview(secondView)

            return splitView
        }
    }

    // MARK: - NSSplitViewDelegate

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

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView,
            splitView.subviews.count >= 2,
            let rootView = currentView,
            let tree = currentTree
        else { return }

        // Compute ratio from the actual divider position
        let firstSize =
            splitView.isVertical
            ? splitView.subviews[0].frame.width
            : splitView.subviews[0].frame.height
        let totalSize =
            splitView.isVertical
            ? splitView.bounds.width
            : splitView.bounds.height
        guard totalSize > 0 else { return }
        let newRatio = min(max(firstSize / totalSize, 0.01), 0.99)

        let updatedTree = updatingRatio(in: tree, newRatio: newRatio, matchingSplitView: splitView, rootView: rootView)
        guard updatedTree != tree else { return }
        currentTree = updatedTree
        onRatioChanged?(updatedTree)
    }

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

    /// Apply split positions after layout so bounds are valid.
    private func applySplitPositions(view: NSView, tree: SplitTree) {
        guard case .split(let direction, let first, let second, let ratio) = tree,
            let splitView = view as? NSSplitView
        else { return }

        let dimension = direction == .horizontal ? splitView.bounds.width : splitView.bounds.height
        if dimension > 0 {
            splitView.setPosition(dimension * ratio, ofDividerAt: 0)
        }

        // Recurse into children
        if splitView.subviews.count >= 2 {
            applySplitPositions(view: splitView.subviews[0], tree: first)
            applySplitPositions(view: splitView.subviews[1], tree: second)
        }
    }
}
