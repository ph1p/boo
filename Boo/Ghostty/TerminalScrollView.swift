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
    private let gutter = PromptGutterView()
    /// "Ask agent" pill on the hovered failed command block.
    private let agentButton = FailedBlockButton()
    /// Prompt index of the block `agentButton` belongs to.
    private var agentButtonBlock: Int?
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
        addSubview(gutter)
        agentButton.isHidden = true
        agentButton.target = self
        agentButton.action = #selector(agentButtonClicked(_:))
        addSubview(agentButton)

        ghosttyView.onScrollbarChanged = { [weak self] sb in
            self?.handleScrollbarUpdate(sb)
        }
        ghosttyView.onPromptMarksChanged = { [weak self] in
            self?.refreshGutter()
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
        gutter.frame = bounds
        ghosttyView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSurfaceView()
        refreshGutter()
    }

    private func refreshGutter() {
        gutter.update(from: ghosttyView)
        // Marks moved (scroll, new output): the hovered block may have too.
        if agentButtonBlock != nil { hideAgentButton() }
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
        guard let size = ghosttyView.gridSize, size.rows > 0,
            ghosttyView.bounds.height > 0
        else { return 0 }
        return ghosttyView.bounds.height / CGFloat(size.rows)
    }

    // MARK: - Scrollbar State from Ghostty

    private func handleScrollbarUpdate(_ sb: GhosttyView.GhosttyScrollbar) {
        currentScrollbar = sb
        synchronizeScrollView()
        refreshGutter()
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

    private static let scrollerArea = "scroller"

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        super.updateTrackingAreas()
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: convert(scroller.bounds, from: scroller),
                options: [.mouseMoved, .activeInKeyWindow],
                owner: self, userInfo: ["area": Self.scrollerArea]))
    }

    override func mouseMoved(with event: NSEvent) {
        if event.trackingArea?.userInfo?["area"] as? String == Self.scrollerArea {
            guard NSScroller.preferredScrollerStyle == .legacy else { return }
            scrollView.flashScrollers()
            return
        }
        updateAgentButton(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo == nil else { return }
        hideAgentButton()
    }

    // MARK: - Failed block → agent

    /// Shows the agent button on the failed block under `point`, at the right
    /// end of its prompt line (or the top line when that scrolled away).
    private func updateAgentButton(at point: NSPoint) {
        guard AppSettings.shared.errorAgentButtonEnabled, ghosttyView.tabID != nil,
            let cellHeight = ghosttyView.cellHeight, cellHeight > 0
        else { return hideAgentButton() }
        if !agentButton.isHidden, agentButton.frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        guard let row = ghosttyView.viewportRow(at: ghosttyView.convert(point, from: self)),
            let block = ghosttyView.promptIndex(atViewportRow: row),
            let mark = ghosttyView.promptMarks().first(where: { $0.index == block }), mark.status == .failed
        else { return hideAgentButton() }
        guard block != agentButtonBlock || agentButton.isHidden else { return }
        agentButtonBlock = block
        let size = agentButton.fittingSize
        let top = GhosttyView.gridPadding + CGFloat(max(0, mark.row)) * cellHeight
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        agentButton.frame =
            NSRect(
                x: bounds.width - size.width - scroller - 6,
                y: bounds.height - top - (cellHeight + size.height) / 2,
                width: size.width, height: size.height
            ).integral
        agentButton.isHidden = false
    }

    private func hideAgentButton() {
        agentButton.isHidden = true
        agentButtonBlock = nil
    }

    @objc private func agentButtonClicked(_ sender: NSButton) {
        guard let block = agentButtonBlock,
            let menu = AgentHandoffMenuTarget.shared.failedBlockMenu(for: ghosttyView, block: block)
        else { return NSSound.beep() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// Small themed pill: "✦ Ask agent".
private final class FailedBlockButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        imagePosition = .imageLeading
        image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        toolTip = "Send this failed command and its output to an agent"
        setAccessibilityLabel("Send failed command to agent")
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isHidden: Bool {
        didSet { if !isHidden { applyTheme() } }
    }

    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(width: size.width + 12, height: 18)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.cardBg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = theme.error.withAlphaComponent(0.6).cgColor
        contentTintColor = theme.error
        attributedTitle = NSAttributedString(
            string: "Ask agent",
            attributes: [.foregroundColor: theme.chromeText, .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
    }
}
