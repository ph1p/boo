import Cocoa
import CGhostty

protocol PaneViewDelegate: AnyObject {
    func paneView(_ paneView: PaneView, didFocus paneID: UUID)
    func paneView(_ paneView: PaneView, didChangeDirectory path: String, paneID: UUID)
    func paneView(_ paneView: PaneView, titleChanged title: String, paneID: UUID)
    func paneView(_ paneView: PaneView, foregroundProcessChanged name: String, paneID: UUID)
    func paneView(_ paneView: PaneView, remoteStateChanged session: RemoteSessionType?, remoteCwd: String?, paneID: UUID)
    func paneView(_ paneView: PaneView, remoteConnectionFailed session: RemoteSessionType, paneID: UUID)
    func paneView(_ paneView: PaneView, sessionEnded paneID: UUID)
}

/// A pane: optional tab bar on top + GhosttyView below.
/// Each tab has its own Ghostty surface. CWD and process tracking
/// comes exclusively from Ghostty's action callbacks (OSC 7, title).
class PaneView: NSView {
    let paneID: UUID
    weak var paneDelegate: PaneViewDelegate?

    private let pane: Pane
    private let tabBarHeight: CGFloat = 26

    private var ghosttyView: GhosttyView?
    private var tabViews: [UUID: GhosttyView] = [:]

    init(paneID: UUID, pane: Pane) {
        self.paneID = paneID
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentTerminalView: NSView? { ghosttyView }

    // MARK: - Terminal Lifecycle

    func startActiveSession() {
        guard let tab = pane.activeTab else { return }

        if let stored = tabViews.removeValue(forKey: tab.id) {
            ghosttyView?.removeFromSuperview()
            addSubview(stored)
            ghosttyView = stored
        } else if ghosttyView == nil {
            let gv = GhosttyView(workingDirectory: tab.workingDirectory)
            wireCallbacks(gv)
            addSubview(gv)
            ghosttyView = gv
        }
        layoutTerminalView()
    }

    private func wireCallbacks(_ gv: GhosttyView) {
        gv.onFocused = { [weak self] in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, didFocus: self.paneID)
        }

        gv.onPwdChanged = { [weak self] path in
            guard let self = self else { return }
            let idx = self.pane.activeTabIndex
            if idx >= 0 { self.pane.updateWorkingDirectory(at: idx, path) }
            self.needsDisplay = true
            self.paneDelegate?.paneView(self, didChangeDirectory: path, paneID: self.paneID)
        }

        gv.onTitleChanged = { [weak self] title in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, titleChanged: title, paneID: self.paneID)

            let idx = self.pane.activeTabIndex
            if idx >= 0 { self.pane.updateTitle(at: idx, title) }
            self.needsDisplay = true
        }

        gv.onProcessExited = { [weak self] in
            guard let self = self else { return }
            self.paneDelegate?.paneView(self, sessionEnded: self.paneID)
        }
    }

    // MARK: - Layout

    func layoutTerminalView() {
        guard let gv = ghosttyView else { return }
        let showTabs = pane.tabs.count > 1
        let tabH = showTabs ? tabBarHeight : 0
        let newFrame = NSRect(x: 0, y: tabH, width: bounds.width, height: max(0, bounds.height - tabH))
        if gv.frame != newFrame { gv.frame = newFrame }
    }

    override func layout() {
        super.layout()
        layoutTerminalView()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }

    // MARK: - Tab Management

    func activateTab(_ index: Int) {
        guard index != pane.activeTabIndex else { return }
        storeCurrentView()
        pane.setActiveTab(index)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        window?.makeFirstResponder(ghosttyView)
        if let tab = pane.activeTab {
            paneDelegate?.paneView(self, didChangeDirectory: tab.workingDirectory, paneID: paneID)
        }
    }

    func addNewTab(workingDirectory: String) {
        storeCurrentView()
        _ = pane.addTab(workingDirectory: workingDirectory)
        startActiveSession()
        layoutTerminalView()
        needsDisplay = true
        window?.makeFirstResponder(ghosttyView)
    }

    func closeTab(at index: Int) {
        let tabID = pane.tabs[index].id
        if let gv = tabViews.removeValue(forKey: tabID) { gv.destroy() }
        if pane.activeTabIndex == index {
            ghosttyView?.destroy()
            ghosttyView?.removeFromSuperview()
            ghosttyView = nil
        }

        let wasActive = index == pane.activeTabIndex
        pane.removeTab(at: index)
        if pane.tabs.isEmpty { return }
        if wasActive {
            startActiveSession()
            layoutTerminalView()
            window?.makeFirstResponder(ghosttyView)
            if let tab = pane.activeTab {
                paneDelegate?.paneView(self, didChangeDirectory: tab.workingDirectory, paneID: paneID)
            }
        } else {
            layoutTerminalView()
        }
        needsDisplay = true
    }

    private func storeCurrentView() {
        guard let gv = ghosttyView, let tab = pane.activeTab else { return }
        gv.removeFromSuperview()
        tabViews[tab.id] = gv
        ghosttyView = nil
    }

    var tabCount: Int { pane.tabs.count }

    // MARK: - Drawing (tab bar)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppSettings.shared.theme
        guard pane.tabs.count > 1 else { return }

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
                ctx.setFillColor(theme.background.cgColor)
                ctx.addPath(CGPath(roundedRect: tabRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.fillPath()
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: isActive ? .medium : .regular),
                .foregroundColor: isActive ? theme.chromeText : theme.chromeMuted
            ]
            let title = tab.title as NSString
            let titleSize = title.size(withAttributes: attrs)
            title.draw(in: CGRect(x: x + 8, y: tabRect.midY - titleSize.height / 2,
                                  width: min(titleSize.width, tabW - 22), height: titleSize.height),
                       withAttributes: attrs)

            if pane.tabs.count > 1 {
                let ca: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: theme.chromeMuted.withAlphaComponent(0.6)
                ]
                let cs = "\u{2715}" as NSString
                let csz = cs.size(withAttributes: ca)
                cs.draw(at: NSPoint(x: x + tabW - csz.width - 8, y: tabRect.midY - csz.height / 2), withAttributes: ca)
            }
            x += tabW
        }

        let pa: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .light),
            .foregroundColor: theme.chromeMuted.withAlphaComponent(0.6)
        ]
        ("+" as NSString).draw(at: NSPoint(x: x + 4, y: (tabBarHeight - ("+" as NSString).size(withAttributes: pa).height) / 2), withAttributes: pa)
    }

    // MARK: - Mouse (tab bar)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard pane.tabs.count > 1, point.y < tabBarHeight else { return }

        let tabW: CGFloat = min(120, max(60, (bounds.width - 24) / CGFloat(pane.tabs.count)))
        var x: CGFloat = 4

        for (i, _) in pane.tabs.enumerated() {
            if point.x >= x && point.x < x + tabW {
                if point.x > x + tabW - 18 && pane.tabs.count > 1 { closeTab(at: i) }
                else { activateTab(i) }
                return
            }
            x += tabW
        }

        if point.x >= x && point.x < x + 24 {
            addNewTab(workingDirectory: pane.activeTab?.workingDirectory ?? "~")
        }
    }

    // MARK: - Cleanup

    func stopAll() {
        for (_, gv) in tabViews { gv.destroy() }
        tabViews.removeAll()
        ghosttyView?.destroy()
        ghosttyView?.removeFromSuperview()
        ghosttyView = nil
    }

    deinit { stopAll() }
}
