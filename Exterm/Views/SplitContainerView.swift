import Cocoa

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView
}

class SplitContainerView: NSView {
    weak var splitDelegate: SplitContainerDelegate?

    private var currentView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let bg = AppSettings.shared.theme.background
        layer?.backgroundColor = bg.nsColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tree: SplitTree) {
        currentView?.removeFromSuperview()
        let view = buildView(from: tree)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        currentView = view
    }

    private func buildView(from tree: SplitTree) -> NSView {
        switch tree {
        case .leaf(let id):
            guard let delegate = splitDelegate else { return NSView() }
            return delegate.splitContainer(self, paneViewFor: id)

        case .split(let direction, let first, let second, let ratio):
            let splitView = ThemedSplitView()
            splitView.isVertical = (direction == .horizontal)
            splitView.dividerStyle = .thin

            let firstView = buildView(from: first)
            let secondView = buildView(from: second)

            splitView.addSubview(firstView)
            splitView.addSubview(secondView)

            splitView.setPosition(
                (direction == .horizontal ? bounds.width : bounds.height) * ratio,
                ofDividerAt: 0
            )

            return splitView
        }
    }
}
