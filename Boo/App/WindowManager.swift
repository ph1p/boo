import Cocoa

/// Owns every main window. Each window has its own `MainWindowController`
/// (own workspaces, sidebar, plugin registry); settings, themes and bookmarks
/// stay global.
///
/// App-wide entry points (unix socket, remote control, notification clicks,
/// ghostty actions without a surface) are routed through here to the active
/// window instead of whichever controller registered a closure last.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [MainWindowController] = []
    /// Most recently main window. Fallback when no Boo window is key
    /// (settings window focused, app inactive).
    private weak var lastActive: MainWindowController?
    /// Controller whose actions the app-wide main menu currently targets.
    weak var menuOwner: MainWindowController?
    private var sharedHandlersInstalled = false
    private var settingsObserver: NSObjectProtocol?
    /// Set once the app is quitting: closing windows then stay in the session.
    private(set) var isTerminating = false

    private init() {}

    /// Window that receives untargeted commands: key window first, then the
    /// last main one, then the oldest.
    var activeController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController, isManaged(key) {
            return key
        }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController, isManaged(main) {
            return main
        }
        if let last = lastActive, isManaged(last) { return last }
        return controllers.first
    }

    /// Oldest open window; runs app-wide side effects once (see `isPrimary`).
    var primaryController: MainWindowController? { controllers.first }

    /// Whether `controller` is the window that feeds app-wide projections
    /// (`AppStore.shared`). True when nothing is managed (tests).
    func isActive(_ controller: MainWindowController) -> Bool {
        activeController.map { $0 === controller } ?? true
    }

    func ownsMenu(_ controller: MainWindowController) -> Bool {
        menuOwner.map { $0 === controller } ?? true
    }

    /// Whether `controller` should run app-wide side effects that every window
    /// would otherwise repeat. Unmanaged controllers (tests) count as primary.
    func isPrimary(_ controller: MainWindowController) -> Bool {
        primaryController.map { $0 === controller } ?? true
    }

    func isManaged(_ controller: MainWindowController) -> Bool {
        controllers.contains { $0 === controller }
    }

    // MARK: - Lifecycle

    /// Reattaches the tmux sessions Boo showed when it quit
    /// (`tmuxReattachOnLaunch`); local ones only while they still exist.
    private func reattachTmuxSessions() {
        let sessions = TmuxControlClient.takeSessionsAttachedAtQuit()
        let settings = AppSettings.shared
        guard settings.tmuxIntegration, settings.tmuxReattachOnLaunch, !sessions.isEmpty else { return }
        // Starts the background fetch the check below reads.
        _ = TmuxSessions.local()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard
                let controller = self?.controllers.first(where: { $0.window?.isKeyWindow == true })
                    ?? self?.controllers.first
            else { return }
            let local = Set(TmuxSessions.local().map(\.name))
            for entry in sessions where entry.host != nil || local.contains(entry.session) {
                controller.startTmuxSession(entry.session, host: entry.host)
            }
        }
    }

    /// Windows at launch: restores every saved window (or one fresh window).
    /// The first keeps the frame autosave; the saved key window ends up key.
    @discardableResult
    func openInitialWindow() -> MainWindowController {
        installSharedHandlers()
        let snapshot = SessionStore.load()
        // Restored tabs pick their agents up while the windows below are built.
        let resumeAgents = shouldResumeAgents(in: snapshot)
        CrashRecovery.resumeOnRestore = resumeAgents
        defer {
            CrashRecovery.resumeOnRestore = false
            announceRecovery(resumed: resumeAgents ? snapshot.map(Self.agentCount) ?? 0 : 0)
            reattachTmuxSessions()
            if resumeAgents, AppSettings.shared.resumeAgentsImmediately {
                // After the windows have laid out, so background terminals get a real size.
                DispatchQueue.main.async { [weak self] in
                    for controller in self?.controllers ?? [] { controller.startResumedAgents() }
                }
            }
        }
        QuickTerminalController.shared.restore(snapshot?.quickTerminal)
        var saved = snapshot?.allWindows ?? []
        var keyIndex = snapshot?.resolvedKeyWindowIndex ?? 0
        // Extra windows whose folders all vanished would restore as default windows.
        if saved.count > 1 {
            let keep = saved.indices.filter { SessionStore.hasRestorableWorkspace(saved[$0]) }
            if !keep.isEmpty {
                keyIndex = keep.firstIndex(of: keyIndex) ?? 0
                saved = keep.map { saved[$0] }
            }
        }
        guard !saved.isEmpty else {
            let controller = MainWindowController(restoreSession: true)
            register(controller)
            show(controller, fullScreen: false)
            OrchestratorController.shared.restore(snapshot?.orchestrator, in: [controller])
            return controller
        }

        let restored = saved.enumerated().map { index, window in
            MainWindowController(restoreSession: index == 0, restoring: window)
        }
        for controller in restored { register(controller) }
        for (index, controller) in restored.enumerated() where index != keyIndex {
            show(controller, fullScreen: saved[index].isFullScreen == true)
        }
        let key = restored[keyIndex]
        show(key, fullScreen: saved[keyIndex].isFullScreen == true)
        OrchestratorController.shared.restore(snapshot?.orchestrator, in: restored)
        writeSession(from: key, sync: false)
        return key
    }

    /// Saves the session in the background, from whichever window is in front.
    /// The agents saved in `snapshot`, across all windows.
    static func agentCount(in snapshot: SessionSnapshot) -> Int {
        snapshot.allWindows.reduce(0) { total, window in
            total
                + window.workspaces.reduce(0) { sum, ws in
                    sum + ws.panes.reduce(0) { $0 + $1.tabs.filter { $0.agent != nil }.count }
                }
        }
    }

    /// Whether this launch restarts the agents saved in `snapshot`; asks first in `.ask` mode.
    private func shouldResumeAgents(in snapshot: SessionSnapshot?) -> Bool {
        guard let snapshot, CrashRecovery.shouldResumeAgents() else { return false }
        let count = Self.agentCount(in: snapshot)
        guard count > 0 else { return false }
        switch AppSettings.shared.agentRecovery {
        case .resume: return true
        case .off: return false
        case .ask:
            let alert = NSAlert()
            alert.messageText = CrashRecovery.previousRunEnd?.title ?? "Resume your agents?"
            alert.informativeText =
                "\(count) agent \(count == 1 ? "session was" : "sessions were") running. "
                + "Resume \(count == 1 ? "it" : "them") in \(count == 1 ? "its tab" : "their tabs")?\n\n"
                + "Change this in Settings → Terminal → Sessions."
            alert.addButton(withTitle: "Resume")
            alert.addButton(withTitle: "Don't Resume")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// After a crash or kill, says the session came back (and how many agents resume).
    private func announceRecovery(resumed count: Int) {
        guard let cause = CrashRecovery.previousRunEnd?.cause else { return }
        let message =
            count > 0
            ? "Recovered from \(cause). \(count) agent\(count == 1 ? " resumes" : "s resume") in \(count == 1 ? "its tab" : "their tabs")."
            : "Recovered your session after \(cause)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { BooAlert.showTransient(message) }
    }

    // MARK: - Autosave

    private var autosaveTimer: Timer?
    private var autosaveTicks = 0
    static let autosaveInterval: TimeInterval = 30
    /// Scrollback is costlier to read, so it's written every this many autosaves.
    static let scrollbackAutosaveEvery = 4

    /// Saves the session every 30 s and scrollback every 2 min, so a crash
    /// loses little: tabs, their directories and the agents to resume.
    func startAutosave() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    private func autosave() {
        guard !isTerminating, controllers.contains(where: \.persistsSession) else { return }
        autosaveTicks += 1
        for controller in controllers where controller.persistsSession {
            controller.prepareSessionSave()
        }
        if autosaveTicks % Self.scrollbackAutosaveEvery == 0, AppSettings.shared.restoreScrollback {
            writeScrollback()
        }
        saveSessionSoon()
    }

    func saveSessionSoon() {
        guard let controller = activeController ?? controllers.first else { return }
        writeSession(from: controller, sync: false)
    }

    private func show(_ controller: MainWindowController, fullScreen: Bool) {
        // Without a first responder, ordering front focuses the first key view
        // (the explorer filter field), which wakes macOS AutoFill's empty panel.
        if let paneID = controller.activeWorkspace?.activePaneID { controller.paneViews[paneID]?.focusActiveView() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if fullScreen, controller.window?.styleMask.contains(.fullScreen) == false {
            controller.window?.toggleFullScreen(nil)
        }
    }

    /// Additional window starting with a fresh default workspace, cascaded
    /// from the current key window.
    @discardableResult
    func newWindow() -> MainWindowController {
        installSharedHandlers()
        let anchor = activeController?.window
        let controller = MainWindowController(restoreSession: false)
        if let window = controller.window, let anchor {
            window.setFrame(anchor.frame, display: false)
            let topLeft = NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        }
        present(controller)
        return controller
    }

    /// New window holding a workspace dragged out of another window, its
    /// top-left corner near the drop point.
    @discardableResult
    func newWindow(
        adopting detached: DetachedWorkspace, at screenPoint: NSPoint, size: NSSize?
    ) -> MainWindowController {
        installSharedHandlers()
        let controller = MainWindowController(restoreSession: false, adopting: detached)
        if let window = controller.window {
            var frame = window.frame
            if let size { frame.size = size }
            frame.origin = NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 12 - frame.height)
            let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? window.screen
            if let screen { frame = window.constrainFrameRect(frame, to: screen) }
            window.setFrame(frame, display: false)
        }
        present(controller)
        return controller
    }

    private func present(_ controller: MainWindowController) {
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        writeSession(from: controller, sync: false)
    }

    /// Frontmost managed window containing `point` (screen coordinates).
    func controller(atScreenPoint point: NSPoint, excluding excluded: MainWindowController?) -> MainWindowController? {
        // Front-to-back order of this app's windows on the active space.
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        for number in numbers {
            guard
                let controller = controllers.first(where: { $0.window?.windowNumber == number.intValue }),
                controller !== excluded,
                let window = controller.window, window.isVisible, !window.isMiniaturized,
                window.frame.contains(point)
            else { continue }
            return controller
        }
        return nil
    }

    /// Controller whose active workspace shows `paneView`.
    func controller(showing paneView: PaneView) -> MainWindowController? {
        controllers.first { $0.paneViews[paneView.paneID] === paneView }
    }

    /// Every registered window is part of the session.
    func register(_ controller: MainWindowController) {
        guard !isManaged(controller) else { return }
        controller.persistsSession = true
        controllers.append(controller)
        lastActive = controller
    }

    func windowDidBecomeMain(_ controller: MainWindowController) {
        guard isManaged(controller) else { return }
        lastActive = controller
    }

    /// Called from `windowWillClose`, which then saves the remaining windows.
    func remove(_ controller: MainWindowController) {
        guard let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        controllers.remove(at: index)
        if lastActive === controller { lastActive = nil }
    }

    // MARK: - Session

    /// Write the session file: every persisting window when `controller` is
    /// managed, only `controller` otherwise (tests, unregistered windows).
    /// Snapshots are built here on the main thread; `sync: false` encodes and
    /// writes in the background.
    func writeSession(from controller: MainWindowController, sync: Bool) {
        guard controller.persistsSession else { return }
        let windows = isManaged(controller) ? controllers.filter(\.persistsSession) : [controller]
        let keyIndex = windows.firstIndex { $0 === activeController } ?? 0
        var snapshot = SessionSnapshot(
            windows: windows.map { $0.sessionWindow() }, keyWindowIndex: keyIndex)
        snapshot.orchestrator = OrchestratorController.shared.session
        snapshot.quickTerminal = QuickTerminalController.shared.session
        if sync {
            SessionStore.save(snapshot)
        } else {
            SessionStore.saveAsync(snapshot)
        }
    }

    /// Write every terminal tab's screen for the next launch to replay.
    private func saveScrollback() {
        ScrollbackStore.clear()
        guard AppSettings.shared.restoreScrollback else { return }
        writeScrollback()
    }

    /// Writes every open terminal's screen; files of closed tabs stay until
    /// the next launch prunes them.
    private func writeScrollback() {
        for controller in controllers where controller.persistsSession {
            for paneView in controller.paneViews.values {
                for (tabID, view) in paneView.terminalViewsByTab {
                    if let text = view.readScreenStyled() { ScrollbackStore.save(text, for: tabID) }
                }
            }
        }
    }

    /// Final save on quit: flush every window's live state, then write all
    /// windows synchronously. Windows closing afterwards stay in the session.
    func saveSessionForTermination() {
        isTerminating = true
        guard let first = controllers.first else { return }
        for controller in controllers {
            controller.coordinator?.saveSidebarStateToSettings()
            controller.prepareSessionSave()
        }
        saveScrollback()
        writeSession(from: first, sync: true)
    }

    /// Controller holding the workspace with `id`, if any window does.
    func controller(owningWorkspace id: UUID) -> MainWindowController? {
        controllers.first { c in c.appState.workspaces.contains { $0.id == id } }
    }

    /// Controller holding the pane with `id`, if any window does.
    func controller(owningPane id: UUID) -> MainWindowController? {
        controllers.first { $0.appState.workspaceContainingPane(id) != nil }
    }

    // MARK: - Shared handlers

    /// Socket and remote-control servers hold a single closure each; install
    /// it once here and dispatch to the active window.
    func installSharedHandlers() {
        guard !sharedHandlersInstalled else { return }
        sharedHandlersInstalled = true
        ApprovalCenter.shared.startObserving()
        OrchestratorEvents.shared.startObserving()
        OrchestratorController.shared.startObserving()
        AgentCrew.shared.startObserving()

        // Only socket traffic is gated; remote control has its own bearer auth.
        BooSocketServer.shared.onControlCommand = { cmd, json, reply in
            DispatchQueue.main.async {
                WindowManager.shared.dispatchGated(cmd: cmd, json: json, reply: reply)
            }
        }
        RemoteControlServer.shared.onCommand = { cmd, json, reply in
            DispatchQueue.main.async {
                WindowManager.shared.dispatchCommand(cmd: cmd, json: json, reply: reply)
            }
        }
        BooSocketServer.shared.onExternalSegmentsChanged = { segments in
            MainActor.assumeIsolated {
                for c in WindowManager.shared.controllers {
                    c.updateExternalStatusBarSegments(segments)
                }
            }
        }
        // App-wide reactions to settings changes; per-window chrome updates stay
        // in each controller's own observer.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { notification in
            let topicString = notification.userInfo?["topic"] as? String
            MainActor.assumeIsolated {
                let topic = topicString.flatMap(SettingsTopic.init(rawValue:))
                if let topic {
                    BooSocketServer.shared.emitSettingsChanged(topic: topic.rawValue)
                }
                // The agents switch is the agents plugin's enabled state.
                let agentsFlipped = (topic == nil || topic == .plugins) && BooPaths.syncAgentIntegration()
                // Rebuild so removed overrides fall back to the built-in shortcuts.
                if topic == .shortcuts, let owner = WindowManager.shared.menuOwner {
                    owner.setupMenuItems()
                    owner.rebuildPluginsMenu()
                } else if agentsFlipped {
                    WindowManager.shared.menuOwner?.rebuildAgentsMenu()
                }
                // Off: badges, the inbox segment and jump all read the inbox.
                if agentsFlipped && !AppSettings.shared.agentsEnabled { AgentInbox.shared.clear() }
                if topic == nil || topic == .theme {
                    AppStore.shared.refreshTheme()
                    let theme = AppSettings.shared.theme
                    BooSocketServer.shared.emitThemeChanged(name: theme.name, isDark: theme.isDark)
                }
            }
        }
        BooSocketServer.shared.onStatusChanged = {
            MainActor.assumeIsolated {
                for c in WindowManager.shared.controllers {
                    c.bridge.reevaluateSocketProcess()
                }
            }
        }
    }

    func dispatchCommand(
        cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) {
        #if DEBUG
            if handleDebugCommand(cmd: cmd, json: json, reply: reply) { return }
        #endif
        if cmd == "agent_timeline" {
            AgentInbox.shared.timeline(json, reply: reply)
            return
        }
        if cmd == "wait_for_events" {
            OrchestratorEvents.shared.handleSocketCommand(json, reply: reply)
            return
        }
        if let response = AgentCrew.shared.handleSocketCommand(
            cmd: cmd, json: json,
            caller: callerTab(CapabilityTokens.shared.resolve(json["token"] as? String), json))
        {
            reply(response)
            return
        }
        if let response = AgentInbox.shared.handleSocketCommand(cmd: cmd, json: json) {
            reply(response)
            return
        }
        if dispatchAppWide(cmd: cmd, json: json, reply: reply) { return }
        // A command naming a pane goes to the window holding it, which may be in the background.
        let paneID = (json["pane_id"] as? String).flatMap(UUID.init(uuidString:))
        if let paneID, OrchestratorController.shared.isOrchestratorPane(paneID) {
            OrchestratorController.shared.handleIPCCommand(cmd: cmd, json: json, reply: reply)
            return
        }
        guard let target = paneID.flatMap(controller(owningPane:)) ?? activeController else {
            reply(["ok": false, "error": "no window"])
            return
        }
        target.handleIPCCommand(cmd: cmd, json: json, reply: reply)
    }
}
