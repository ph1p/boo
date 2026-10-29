import CGhostty
import Cocoa

/// What survives a relaunch: each tab's directory and the selected tab.
struct QuickTerminalSession: Codable, Sendable, Equatable {
    var tabs: [String]
    var activeIndex: Int = 0
}

/// The dropdown terminal on a global hotkey (default ⌥Space).
///
/// Its tabs are `DetachedPaneHost`s shown one at a time in a floating panel
/// that slides down from the top of the screen under the mouse. Hiding only
/// orders the panel out; the shells keep running. Tabs have no splits: the
/// split tree belongs to `MainWindowController`.
///
/// The controller is the panel's delegate, so while the panel is key it sits
/// in the responder chain ahead of the main window: tab and terminal menu
/// commands act here, and pane commands are disabled instead of reaching the
/// window behind.
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = QuickTerminalController()

    private(set) var hosts: [DetachedPaneHost] = []
    private(set) var activeIndex = 0
    /// Saved tabs not reopened yet; shells start on first show, not at launch.
    private var pendingRestore: QuickTerminalSession?

    private var panel: QuickTerminalPanel?
    private var content: QuickTerminalContentView?
    private var hotKey: GlobalHotKey?
    /// Why the configured hotkey is not active, for the settings page.
    private(set) var hotKeyProblem: String?
    private var previousApp: NSRunningApplication?
    private var isAnimating = false
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    override init() { super.init() }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    var isVisible: Bool { panel?.isVisible == true }

    var activeHost: DetachedPaneHost? { hosts.indices.contains(activeIndex) ? hosts[activeIndex] : nil }

    /// Registers the hotkey and follows settings changes.
    func start() {
        configureHotKey()
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureHotKey()
                self?.layoutPanel()
            }
        }
    }

    func configureHotKey() {
        let settings = AppSettings.shared
        guard settings.quickTerminalEnabled else {
            hotKey = nil
            hotKeyProblem = nil
            updateMenuItem()
            return
        }
        guard let spec = HotKeySpec.parse(settings.quickTerminalHotkey) else {
            hotKey = nil
            hotKeyProblem = "\"\(settings.quickTerminalHotkey)\" is not a valid shortcut"
            updateMenuItem()
            return
        }
        guard hotKey?.spec != spec else { return }
        hotKey = nil  // Release the old combination before claiming the new one.
        hotKey = GlobalHotKey(spec: spec) { [weak self] in self?.toggle() }
        hotKeyProblem = hotKey == nil ? "\(spec.display) is taken by another app" : nil
        updateMenuItem()
    }

    /// Mirrors the hotkey on Window → Toggle Quick Terminal. The hotkey wins
    /// over the menu while registered, so the two never both fire.
    func updateMenuItem() {
        guard let item = Self.findItem(action: #selector(toggleQuickTerminalAction(_:)), in: NSApp.mainMenu)
        else { return }
        configure(item)
    }

    func configure(_ item: NSMenuItem) {
        if let spec = hotKey?.spec {
            let equivalent = spec.menuKeyEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private static func findItem(action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = findItem(action: action, in: item.submenu) { return found }
        }
        return nil
    }

    // MARK: - Show / Hide

    @objc func toggleQuickTerminalAction(_ sender: Any?) { toggle() }

    func toggle() {
        if isVisible, panel?.isKeyWindow == true {
            hide(restoringFocus: true)
        } else {
            show()
        }
    }

    func show() {
        guard !isAnimating else { return }
        let panel = ensurePanel()
        if hosts.isEmpty { reopenTabs() }
        if !panel.isVisible {
            previousApp = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
        }
        // Activate first: activation picks a key window, which must end up the panel.
        NSApp.activate()
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            activeHost?.focus()
            return
        }
        let target = targetFrame()
        panel.setFrame(target.offsetBy(dx: 0, dy: target.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        select(activeIndex)
        animate(panel, to: target) { [weak self] in self?.activeHost?.focus() }
    }

    /// `restoringFocus` gives focus back to the app that was in front before
    /// the panel opened (only when the panel itself was focused).
    func hide(restoringFocus: Bool) {
        guard let panel, panel.isVisible, !isAnimating else { return }
        let target = panel.frame.offsetBy(dx: 0, dy: panel.frame.height)
        let previous = restoringFocus ? previousApp : nil
        previousApp = nil
        animate(panel, to: target) {
            panel.orderOut(nil)
            if let previous, previous != NSRunningApplication.current { previous.activate() }
        }
    }

    private func animate(_ panel: NSPanel, to frame: NSRect, completion: @escaping @MainActor @Sendable () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            completion()
            return
        }
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.isAnimating = false
                completion()
            }
        }
    }

    /// Full width of the screen under the mouse, hanging from its top edge.
    func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return Self.frame(in: visible, heightFraction: AppSettings.shared.quickTerminalHeight)
    }

    nonisolated static func frame(in visible: NSRect, heightFraction: Double) -> NSRect {
        let height = (visible.height * CGFloat(heightFraction)).rounded()
        return NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
    }

    private func layoutPanel() {
        guard let panel, panel.isVisible, !isAnimating else { return }
        let target = targetFrame()
        if panel.frame.size != target.size { panel.setFrame(target, display: true) }
    }

    private func ensurePanel() -> QuickTerminalPanel {
        if let panel { return panel }
        let panel = QuickTerminalPanel()
        let content = QuickTerminalContentView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.tabStrip.onSelect = { [weak self] in self?.select($0) }
        content.tabStrip.onClose = { [weak self] in self?.closeTab(at: $0) }
        content.tabStrip.onNew = { [weak self] in self?.newTab() }
        panel.contentView = content
        panel.delegate = self
        self.panel = panel
        self.content = content
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard AppSettings.shared.quickTerminalHideOnResign, !isAnimating else { return }
        hide(restoringFocus: false)
    }

    // MARK: - Tabs

    /// Opens a tab in `directory`, or the active tab's directory.
    func newTab(in directory: String? = nil) {
        let cwd = directory ?? activeHost?.workingDirectory ?? NSHomeDirectory()
        let host = DetachedPaneHost(workingDirectory: cwd, title: cwd.lastPathComponent)
        host.onTitleChanged = { [weak self] _ in self?.refreshTabStrip() }
        host.onExited = { [weak self, weak host] in
            guard let self, let host else { return }
            self.tabExited(host)
        }
        host.start()
        hosts.append(host)
        select(hosts.count - 1)
        WindowManager.shared.saveSessionSoon()
    }

    func select(_ index: Int) {
        guard hosts.indices.contains(index) else { return }
        activeIndex = index
        if let container = content?.terminalContainer {
            for (i, host) in hosts.enumerated() where i != index && host.isAttached(to: container) {
                host.park()
            }
            hosts[index].attach(to: container)
            if isVisible { hosts[index].focus() }
        }
        refreshTabStrip()
    }

    func closeTab(at index: Int) {
        guard hosts.indices.contains(index) else { return }
        hosts[index].stop()  // tabExited removes it.
    }

    private func tabExited(_ host: DetachedPaneHost) {
        guard let index = hosts.firstIndex(where: { $0 === host }) else { return }
        hosts.remove(at: index)
        if hosts.isEmpty {
            activeIndex = 0
            refreshTabStrip()
            hide(restoringFocus: panel?.isKeyWindow == true)
        } else {
            select(index < activeIndex ? activeIndex - 1 : min(activeIndex, hosts.count - 1))
        }
        WindowManager.shared.saveSessionSoon()
    }

    private func refreshTabStrip() {
        guard let content else { return }
        content.showsTabs = hosts.count > 1
        content.tabStrip.titles = hosts.map { $0.title.isEmpty ? $0.workingDirectory.lastPathComponent : $0.title }
        content.tabStrip.activeIndex = activeIndex
    }

    private func reopenTabs() {
        let saved = pendingRestore
        pendingRestore = nil
        let directories = (saved?.tabs ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        guard !directories.isEmpty else {
            newTab(in: NSHomeDirectory())
            return
        }
        for directory in directories { newTab(in: directory) }
        select(min(max(saved?.activeIndex ?? 0, 0), hosts.count - 1))
    }

    // MARK: - Session

    var session: QuickTerminalSession? {
        guard !hosts.isEmpty else { return pendingRestore }
        return QuickTerminalSession(tabs: hosts.map(\.workingDirectory), activeIndex: activeIndex)
    }

    func restore(_ saved: QuickTerminalSession?) {
        guard hosts.isEmpty else { return }
        pendingRestore = saved
    }

    /// Closes every tab and forgets the panel (tests).
    func reset() {
        for host in hosts {
            host.onExited = nil
            host.stop()
        }
        hosts = []
        activeIndex = 0
        pendingRestore = nil
        panel?.orderOut(nil)
    }

    // MARK: - Menu Commands (while the panel is key)

    private var focusedTerminal: GhosttyView? {
        guard let terminal = activeHost?.terminal, panel?.firstResponder === terminal else { return nil }
        return terminal
    }

    @objc func newTabAction(_ sender: Any?) { newTab() }

    @objc func smartCloseAction(_ sender: Any?) { closeTab(at: activeIndex) }

    @objc func switchToTabAction(_ sender: NSMenuItem) { select(sender.tag) }

    @objc func focusNextPaneAction(_ sender: Any?) { cycleTab(by: 1) }

    @objc func focusPrevPaneAction(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard !hosts.isEmpty else { return }
        select((activeIndex + delta + hosts.count) % hosts.count)
    }

    @objc func clearScreenAction(_ sender: Any?) {
        activeHost?.terminal?.sendKey(keyCode: 0x25, mods: GHOSTTY_MODS_CTRL, text: "l")
    }

    @objc func clearScrollbackAction(_ sender: Any?) {
        activeHost?.terminal?.sendRaw("printf '\\033[3J\\033[2J\\033[H'\r")
    }

    @objc func jumpToPreviousPromptAction(_ sender: Any?) { focusedTerminal?.jumpToPrompt(-1) }

    @objc func jumpToNextPromptAction(_ sender: Any?) { focusedTerminal?.jumpToPrompt(1) }

    @objc func copyLastOutputAction(_ sender: Any?) { focusedTerminal?.copyLastCommandOutput() }

    @objc func quickSelectAction(_ sender: Any?) { focusedTerminal?.startQuickSelect() }

    // Window-only commands: disabled here so they don't reach the window behind.
    @objc func newBrowserTabAction(_ sender: Any?) {}
    @objc func newTabOfType(_ sender: NSMenuItem) {}
    @objc func splitVerticalAction(_ sender: Any?) {}
    @objc func splitHorizontalAction(_ sender: Any?) {}
    @objc func closePaneAction(_ sender: Any?) {}
    @objc func reopenTabAction(_ sender: Any?) {}
    @objc func toggleZoomPaneAction(_ sender: Any?) {}
    @objc func equalizeSplitsAction(_ sender: Any?) {}
    @objc func focusPaneLeftAction(_ sender: Any?) {}
    @objc func focusPaneRightAction(_ sender: Any?) {}
    @objc func focusPaneUpAction(_ sender: Any?) {}
    @objc func focusPaneDownAction(_ sender: Any?) {}
    @objc func resizePaneLeftAction(_ sender: Any?) {}
    @objc func resizePaneRightAction(_ sender: Any?) {}
    @objc func resizePaneUpAction(_ sender: Any?) {}
    @objc func resizePaneDownAction(_ sender: Any?) {}
    @objc func swapPaneLeftAction(_ sender: Any?) {}
    @objc func swapPaneRightAction(_ sender: Any?) {}
    @objc func swapPaneUpAction(_ sender: Any?) {}
    @objc func swapPaneDownAction(_ sender: Any?) {}
    @objc func findAction(_ sender: Any?) {}
    @objc func saveAction(_ sender: Any?) {}
    @objc func toggleSidebarAction(_ sender: Any?) {}
    @objc func toggleFullScreenAction(_ sender: Any?) {}
    @objc func switchToWorkspaceAction(_ sender: NSMenuItem) {}
    @objc func bookmarkCurrentAction(_ sender: Any?) {}
    @objc func jumpToBookmarkAction(_ sender: NSMenuItem) {}
    @objc func sendContextToAgentAction(_ sender: Any?) {}
    @objc func toggleOrchestratorAction(_ sender: Any?) {}

    static let enabledActions: Set<Selector> = [
        #selector(newTabAction(_:)), #selector(smartCloseAction(_:)), #selector(switchToTabAction(_:)),
        #selector(focusNextPaneAction(_:)), #selector(focusPrevPaneAction(_:)),
        #selector(clearScreenAction(_:)), #selector(clearScrollbackAction(_:)),
        #selector(toggleQuickTerminalAction(_:))
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        switch action {
        case #selector(switchToTabAction(_:)):
            return hosts.indices.contains(menuItem.tag)
        case #selector(toggleQuickTerminalAction(_:)):
            menuItem.state = isVisible ? .on : .off
            return true
        // Disabled items pass the key on, so ⌘↑ reaches the terminal unfocused.
        case #selector(jumpToPreviousPromptAction(_:)), #selector(jumpToNextPromptAction(_:)),
            #selector(copyLastOutputAction(_:)), #selector(quickSelectAction(_:)):
            return focusedTerminal != nil
        default:
            return Self.enabledActions.contains(action)
        }
    }
}
