import Cocoa

protocol PaneViewDelegate: AnyObject {
    func paneView(_ paneView: PaneView, didFocus paneID: UUID)
    func paneView(_ paneView: PaneView, sessionForPane paneID: UUID, tabIndex: Int, workingDirectory: String) -> TerminalSession
    func paneView(_ paneView: PaneView, didChangeDirectory path: String, paneID: UUID)
    func paneView(_ paneView: PaneView, remoteStateChanged session: RemoteSessionType?, remoteCwd: String?, paneID: UUID)
    func paneView(_ paneView: PaneView, remoteConnectionFailed session: RemoteSessionType, paneID: UUID)
}

/// A pane: local tab bar on top + terminal view below. Each tab is a terminal session.
class PaneView: NSView {
    let paneID: UUID
    weak var paneDelegate: PaneViewDelegate?

    private let pane: Pane
    private let tabBarHeight: CGFloat = 26
    private var terminalView: TerminalView?
    private var tabBarLayer = CALayer()
    private var needsTabBarRedraw = true

    init(paneID: UUID, pane: Pane) {
        self.paneID = paneID
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        let bg = AppSettings.shared.theme.background
        layer?.backgroundColor = bg.nsColor.cgColor

        setupTerminalView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentTerminalView: TerminalView? { terminalView }

    private func setupTerminalView() {
        terminalView?.removeFromSuperview()

        let tv = TerminalView(frame: .zero)
        tv.onFocused = { [weak self] in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }
        addSubview(tv)
        terminalView = tv
    }

    func layoutTerminalView() {
        guard let tv = terminalView else { return }
        let showTabs = pane.tabs.count > 1
        let tabH = showTabs ? tabBarHeight : 0
        let newFrame = NSRect(x: 0, y: tabH, width: bounds.width, height: max(0, bounds.height - tabH))
        if tv.frame != newFrame {
            tv.frame = newFrame
        }
    }

    override func layout() {
        super.layout()
        layoutTerminalView()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
        }
    }

    // MARK: - Tab Management

    func activateTab(_ index: Int) {
        guard index != pane.activeTabIndex else { return }

        // Disconnect old session from view (keep it running in background)
        pane.activeSession?.detachFromView()

        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
    }

    func addNewTab(workingDirectory: String) {
        // Disconnect old session from view (session stays alive in background)
        if let oldSession = pane.activeSession {
            oldSession.detachFromView()
        }
        let _ = pane.addTab(workingDirectory: workingDirectory)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
    }

    func closeTab(at index: Int) {
        let wasActive = index == pane.activeTabIndex
        pane.removeTab(at: index)

        if pane.tabs.isEmpty {
            return // Caller should handle closing the pane
        }

        if wasActive {
            startActiveSession()
        }
        layoutTerminalView()
        needsDisplay = true
    }

    func startActiveSession() {
        guard let tv = terminalView,
              let tab = pane.activeTab,
              let delegate = paneDelegate else { return }

        if let existingSession = tab.session {
            existingSession.attachToView(tv)
            existingSession.terminal.ansiPalette = AppSettings.shared.theme.ansiColors
        } else {
            let session = delegate.paneView(self, sessionForPane: paneID, tabIndex: pane.activeTabIndex, workingDirectory: tab.workingDirectory)
            session.terminal.ansiPalette = AppSettings.shared.theme.ansiColors

            session.onDirectoryChanged = { [weak self] newPath in
                guard let self = self else { return }
                self.pane.updateTitle(at: self.pane.activeTabIndex, (newPath as NSString).lastPathComponent)
                self.needsDisplay = true
                self.paneDelegate?.paneView(self, didChangeDirectory: newPath, paneID: self.paneID)
            }

            session.onRemoteStateChanged = { [weak self] session, remoteCwd in
                guard let self = self else { return }
                self.paneDelegate?.paneView(self, remoteStateChanged: session, remoteCwd: remoteCwd, paneID: self.paneID)
            }

            session.onRemoteConnectionFailed = { [weak self] session in
                guard let self = self else { return }
                self.paneDelegate?.paneView(self, remoteConnectionFailed: session, paneID: self.paneID)
            }

            pane.setSession(session, forTabAt: pane.activeTabIndex)
            session.start()
        }
    }

    var tabCount: Int { pane.tabs.count }
    var hasMultipleTabs: Bool { pane.tabs.count > 1 }

    // MARK: - Drawing (tab bar)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme

        let showTabs = pane.tabs.count > 1
        guard showTabs else { return }

        ctx.setFillColor(theme.chromeBg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight))

        ctx.setFillColor(theme.chromeMuted.withAlphaComponent(0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: tabBarHeight - 0.5, width: bounds.width, height: 0.5))

        let tabW: CGFloat = min(120, max(60, (bounds.width - 24) / CGFloat(pane.tabs.count)))
        var x: CGFloat = 4

        for (i, tab) in pane.tabs.enumerated() {
            let isActive = i == pane.activeTabIndex
            let tabRect = CGRect(x: x + 1, y: 3, width: tabW - 2, height: tabBarHeight - 5)

            if isActive {
                let bg = theme.background
                ctx.setFillColor(bg.cgColor)
                ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.fillPath()
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: isActive ? .medium : .regular),
                .foregroundColor: isActive ? theme.chromeText : theme.chromeMuted
            ]
            let title = tab.title as NSString
            let titleSize = title.size(withAttributes: attrs)
            let maxTitleW = tabW - 22
            title.draw(in: CGRect(
                x: x + 8,
                y: tabRect.midY - titleSize.height / 2,
                width: min(titleSize.width, maxTitleW),
                height: titleSize.height
            ), withAttributes: attrs)

            if pane.tabs.count > 1 {
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: theme.chromeMuted.withAlphaComponent(0.6)
                ]
                let closeStr = "\u{2715}" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                closeStr.draw(
                    at: NSPoint(x: x + tabW - closeSize.width - 8, y: tabRect.midY - closeSize.height / 2),
                    withAttributes: closeAttrs
                )
            }

            x += tabW
        }

        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .light),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.6)
        ]
        let plusSize = ("+" as NSString).size(withAttributes: plusAttrs)
        ("+" as NSString).draw(at: NSPoint(x: x + 4, y: (tabBarHeight - plusSize.height) / 2), withAttributes: plusAttrs)
    }

    // MARK: - Mouse (tab bar clicks)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Only handle clicks in the tab bar area when multiple tabs
        guard pane.tabs.count > 1, point.y < tabBarHeight else {
            // Pass through — terminal view handles its own clicks
            return
        }

        let tabW: CGFloat = min(120, max(60, (bounds.width - 24) / CGFloat(pane.tabs.count)))
        var x: CGFloat = 4

        for (i, _) in pane.tabs.enumerated() {
            if point.x >= x && point.x < x + tabW {
                // Close button
                if point.x > x + tabW - 18 && pane.tabs.count > 1 {
                    closeTab(at: i)
                } else {
                    activateTab(i)
                }
                return
            }
            x += tabW
        }

        // Plus button
        if point.x >= x && point.x < x + 24 {
            let cwd = pane.activeSession?.currentDirectory ?? pane.activeTab?.workingDirectory ?? "~"
            addNewTab(workingDirectory: cwd)
        }
    }
}
