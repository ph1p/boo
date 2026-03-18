import Cocoa

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView
}

class SplitContainerView: NSView, NSSplitViewDelegate {
    weak var splitDelegate: SplitContainerDelegate?

    private var currentView: NSView?
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
        // Remove old view hierarchy
        currentView?.removeFromSuperview()
        currentView = nil

        let view = buildView(from: tree)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        currentView = view

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

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + minPaneDimension
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - minPaneDimension
    }

    /// Apply split positions after layout so bounds are valid.
    private func applySplitPositions(view: NSView, tree: SplitTree) {
        guard case .split(let direction, let first, let second, let ratio) = tree,
              let splitView = view as? NSSplitView else { return }

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
