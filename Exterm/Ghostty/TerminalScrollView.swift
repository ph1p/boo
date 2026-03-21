import CGhostty
import Cocoa

/// Wraps a GhosttyView in an NSScrollView to provide a native macOS scrollbar.
///
/// Scroll-wheel / trackpad events always go directly to GhosttyView (and thus to
/// Ghostty's core, which handles momentum/inertia internally).  The NSScrollView
/// is used only to render the scrollbar knob and to support scrollbar dragging.
///
/// This matches Ghostty's own SurfaceScrollView architecture: the NSScrollView
/// never processes scroll-wheel events — it only reflects the terminal's viewport.
class TerminalScrollView: NSView {
    let ghosttyView: GhosttyView
    private let scrollView: NSScrollView
    private let documentView: NSView
    private var currentScrollbar: GhosttyView.GhosttyScrollbar?

    /// True while the user is actively dragging the scrollbar knob.
    private var isLiveScrolling = false

    /// Last row sent via scroll_to_row during scrollbar drag.
    private var lastSentRow: Int?

    init(ghosttyView: GhosttyView) {
        self.ghosttyView = ghosttyView

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.usesPredominantAxisScrolling = true

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(ghosttyView)

        super.init(frame: .zero)
        addSubview(scrollView)

        ghosttyView.onScrollbarChanged = { [weak self] sb in
            self?.handleScrollbarUpdate(sb)
        }

        // Bounds changes — keep surface view pinned to visible rect
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        // Scrollbar drag tracking
        NotificationCenter.default.addObserver(
            self, selector: #selector(willStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView)

        // Keep overlay style
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        ghosttyView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    /// Pin GhosttyView to the visible rect of the scroll view.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        ghosttyView.frame.origin = visibleRect.origin
    }

    /// Update document height and scroll position to reflect Ghostty's viewport.
    /// During scrollbar drag, only updates the document height (not position).
    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = self.cellHeight
            if cellHeight > 0, let sb = currentScrollbar {
                let offsetY = CGFloat(sb.total - sb.offset - sb.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = sb.offset
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = self.cellHeight
        if cellHeight > 0, let sb = currentScrollbar {
            let documentGridHeight = CGFloat(sb.total) * cellHeight
            let padding = contentHeight - (CGFloat(sb.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    private var cellHeight: CGFloat {
        guard let size = ghosttyView.gridSize, size.rows > 0 else { return 0 }
        return ghosttyView.bounds.height / CGFloat(size.rows)
    }

    // MARK: - Scrollbar State from Ghostty

    private func handleScrollbarUpdate(_ sb: GhosttyView.GhosttyScrollbar) {
        currentScrollbar = sb
        synchronizeScrollView()
    }

    // MARK: - Notifications

    @objc private func boundsDidChange(_ note: Notification) {
        synchronizeSurfaceView()
    }

    @objc private func willStartLiveScroll(_ note: Notification) {
        isLiveScrolling = true
    }

    @objc private func didEndLiveScroll(_ note: Notification) {
        isLiveScrolling = false
    }

    /// User is dragging the scrollbar knob — convert position to row.
    @objc private func didLiveScroll(_ note: Notification) {
        let cellHeight = self.cellHeight
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let docHeight = documentView.frame.height
        let scrollOffset = docHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row

        guard let surface = ghosttyView.surface else { return }
        let cmd = "scroll_to_row:\(row)"
        cmd.withCString { cstr in
            _ = ghostty_surface_binding_action(surface, cstr, UInt(cmd.utf8.count))
        }
    }

    @objc private func scrollerStyleDidChange(_ note: Notification) {
        scrollView.scrollerStyle = .overlay
    }

    // MARK: - Scroll Events

    /// All scroll-wheel / trackpad events go directly to GhosttyView.
    /// Ghostty's core handles momentum/inertia internally via the momentum
    /// phase packed into scroll mods — no NSScrollView involvement needed.
    override func scrollWheel(with event: NSEvent) {
        ghosttyView.scrollWheel(with: event)
    }

    // MARK: - Mouse tracking for legacy scroller

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        super.updateTrackingAreas()
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: convert(scroller.bounds, from: scroller),
                options: [.mouseMoved, .activeInKeyWindow],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }
}
