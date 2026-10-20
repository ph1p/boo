import Cocoa

extension Notification.Name {
    /// The orchestrator started, stopped, or its drawer opened, moved or closed.
    static let orchestratorChanged = Notification.Name("BooOrchestratorChanged")
}

/// The app-wide orchestrator: one Claude Code session in a terminal that is in
/// no window's split tree, driving Boo through its MCP server.
///
/// Its tab gets a `gated` token, so writes into panes it did not start go
/// through `ApprovalCenter`. Socket commands naming its pane are routed here
/// by `WindowManager.dispatchCommand`, not to a window.
@MainActor
final class OrchestratorController {
    static let shared = OrchestratorController()

    private(set) var host: DetachedPaneHost?

    var tabID: UUID? { host?.tabID }
    var paneID: UUID? { host?.paneID }
    var isRunning: Bool { host?.isRunning == true }

    init() {}

    /// The host, created on first use (its pane and tab IDs then stay stable
    /// for the app session).
    func ensureHost(workingDirectory: String = NSHomeDirectory()) -> DetachedPaneHost {
        if let host { return host }
        let host = DetachedPaneHost(workingDirectory: workingDirectory, title: "Orchestrator")
        CapabilityTokens.shared.setGrade(.gated, for: host.tabID)
        host.onExited = { [weak self] in self?.terminalExited() }
        self.host = host
        return host
    }

    /// Starts the orchestrator's terminal with `launch` unless it is running.
    func start(_ launch: LaunchSpec) {
        ensureHost().start(launch)
    }

    func stop() {
        host?.stop()
    }

    func isOrchestratorPane(_ paneID: UUID) -> Bool { self.paneID == paneID }

    // MARK: - Launch and persistence

    /// The conversation to resume; the hook's id wins once Claude reports one
    /// (`/clear` starts a new id).
    private(set) var sessionID: String?
    /// Worktrees of the tasks it started; their tabs are owned again after a relaunch.
    private(set) var ownedWorktrees: Set<String> = []
    /// Why the last start failed, shown in the empty state.
    private(set) var launchError: String?
    /// nil until checked.
    private(set) var claudeInstalled: Bool?

    var currentSessionID: String? { AgentInbox.shared.orchestrator?.sessionID ?? sessionID }
    var canResume: Bool { !isRunning && currentSessionID != nil }

    /// What the session snapshot keeps; nil when there is nothing to keep.
    var session: OrchestratorSession? {
        let fm = FileManager.default
        let worktrees = ownedWorktrees.filter { fm.fileExists(atPath: $0) }.sorted()
        guard currentSessionID != nil || !worktrees.isEmpty else { return nil }
        return OrchestratorSession(sessionID: currentSessionID, ownedWorktrees: worktrees)
    }

    /// Starts the orchestrator in the open drawer, resuming the last
    /// conversation when there is one.
    func launch() { launch(resume: true) }

    func newConversation() { launch(resume: false) }

    private func launch(resume: Bool) {
        guard !isRunning else {
            host?.focus()
            return
        }
        let previous = resume ? currentSessionID : nil
        let resumable = previous.map { AgentTimeline.transcriptURL(sessionID: $0) != nil } ?? false
        let id = resumable ? previous! : UUID().uuidString.lowercased()
        do {
            guard let prompt = OrchestratorLaunch.promptURL else { throw LaunchError.missingPrompt }
            let config = try OrchestratorLaunch.writeMCPConfig(executable: Bundle.main.executablePath ?? "Boo")
            let command = OrchestratorLaunch.command(
                sessionID: id, resume: resumable, mcpConfig: config.path, promptFile: prompt.path,
                notice: previous != nil && !resumable ? "Previous conversation unavailable; starting a new one." : nil)
            launchError = nil
            sessionID = id
            start(OrchestratorLaunch.spec(command: command))
        } catch {
            launchError = error.localizedDescription
            changed()
            return
        }
        attachTerminal()
        host?.focus()
        changed()
        WindowManager.shared.saveSessionSoon()
    }

    private enum LaunchError: LocalizedError {
        case missingPrompt
        var errorDescription: String? { "The orchestrator prompt is missing from the app bundle." }
    }

    /// Checks once whether `claude` is installed, for the empty state.
    func checkClaudeInstalled(force: Bool = false) {
        guard force || claudeInstalled == nil else { return }
        Task { @MainActor in
            claudeInstalled = await OrchestratorLaunch.claudeInstalled()
            changed()
        }
    }

    /// Restores the saved session after the windows are back: the conversation
    /// to resume, and ownership of the tabs in its task worktrees.
    func restore(_ saved: OrchestratorSession?, in controllers: [MainWindowController]) {
        guard let saved else { return }
        sessionID = saved.sessionID
        ownedWorktrees = Set(saved.ownedWorktrees)
        let owner = ensureHost().tabID
        for tab in Self.tabsInWorktrees(ownedWorktrees, controllers: controllers) {
            CapabilityTokens.shared.markOwned(tab, by: owner)
        }
        changed()
    }

    /// Notes a worktree task the orchestrator started.
    func recordOwnedWorktree(_ path: String) {
        ownedWorktrees.insert(Self.standardized(path))
    }

    /// Tabs in workspaces opened on, or terminals sitting in, one of `worktrees`.
    static func tabsInWorktrees(_ worktrees: Set<String>, controllers: [MainWindowController]) -> [UUID] {
        guard !worktrees.isEmpty else { return [] }
        func inside(_ path: String) -> Bool {
            let path = standardized(path)
            return worktrees.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var tabs: [UUID] = []
        for controller in controllers {
            for workspace in controller.appState.workspaces {
                let wholeWorkspace = inside(workspace.folderPath)
                for paneID in workspace.splitTree.leafIDs {
                    guard let pane = workspace.pane(for: paneID) else { continue }
                    for tab in pane.tabs
                    where wholeWorkspace || (tab.contentType == .terminal && inside(tab.workingDirectory)) {
                        tabs.append(tab.id)
                    }
                }
            }
        }
        return tabs
    }

    private static func standardized(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    // MARK: - Drawer

    /// The window whose drawer is open; nil while it is closed everywhere.
    private(set) weak var drawerController: MainWindowController?
    private var approvalsHooked = false

    var drawer: OrchestratorDrawerView? { drawerController?.orchestratorDrawer }

    /// Notifies about cards added while the drawer is out of sight.
    func startObserving() {
        guard !approvalsHooked else { return }
        approvalsHooked = true
        ApprovalCenter.shared.onEnqueued = { [weak self] request in
            guard let self, !self.isDrawerInSight else { return }
            let target = Self.targetLabel(request.targetTabIDs)
            ActivityNotifier.shared.notifyOrchestrator(
                title: "Orchestrator: \(request.action)",
                body: [target, request.payload].filter { !$0.isEmpty }.joined(separator: " — "))
        }
    }

    private var isDrawerInSight: Bool {
        NSApp.isActive && drawer != nil && drawerController?.window?.isKeyWindow == true
    }

    func toggleDrawer(in controller: MainWindowController) {
        if drawerController === controller, controller.hasOrchestratorDrawer {
            closeDrawer()
        } else {
            openDrawer(in: controller)
        }
    }

    /// Opens the drawer in `controller`, moving it (and the live terminal) out
    /// of whichever window had it.
    func openDrawer(in controller: MainWindowController) {
        let previous = drawerController
        guard let drawer = controller.installOrchestratorDrawer() else { return }
        drawerController = controller
        // Attach first, so the surface goes straight from window to window.
        attachTerminal()
        if previous !== controller { previous?.removeOrchestratorDrawer() }
        if isRunning {
            host?.focus()
        } else {
            controller.window?.makeFirstResponder(drawer)
            checkClaudeInstalled()
        }
        changed()
    }

    func closeDrawer() {
        guard let controller = drawerController else { return }
        host?.park()
        drawerController = nil
        controller.removeOrchestratorDrawer()
        changed()
    }

    private func attachTerminal() {
        guard let drawer, let host, host.isRunning else { return }
        drawer.terminalContainer.layoutSubtreeIfNeeded()
        host.attach(to: drawer.terminalContainer)
    }

    /// "Claude Code · api" for the cards and notifications.
    static func targetLabel(_ tabs: [UUID], inbox: AgentInbox = .shared) -> String {
        tabs.map { tab in
            let agent = inbox.items[tab].map { AgentInbox.displayName(of: $0.agent) } ?? "Pane"
            guard let workspace = inbox.locate(tab)?.workspace.displayName, !workspace.isEmpty else { return agent }
            return "\(agent) · \(workspace)"
        }.joined(separator: ", ")
    }

    private func changed() {
        NotificationCenter.default.post(name: .orchestratorChanged, object: nil)
    }

    // MARK: - Socket

    /// Commands that name the orchestrator's pane. It only answers reads:
    /// everything else acts on a workspace pane, which it is not.
    func handleIPCCommand(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let host, let paneID else {
            reply(["ok": false, "error": "orchestrator is not running"])
            return
        }
        switch cmd {
        case "get_screen":
            guard let terminal = host.terminal else {
                reply(["ok": false, "error": "pane has no running terminal"])
                return
            }
            let text =
                (json["lines"] as? Int).flatMap { terminal.readRecentText(lines: min($0, 5000)) }
                ?? terminal.readViewportText()
            reply([
                "ok": true, "pane_id": paneID.uuidString, "text": text ?? "", "title": host.title,
                "cwd": host.pane.tabs[0].workingDirectory
            ])
        default:
            reply(["ok": false, "error": "the orchestrator pane is not in a workspace; pass a workspace pane_id"])
        }
    }

    // MARK: - Private

    private func terminalExited() {
        // Keep the id the hook reported before the inbox forgets it.
        sessionID = currentSessionID
        // Its cards can no longer be answered into a running session.
        ApprovalCenter.shared.expireAll()
        AgentInbox.shared.applyOrchestrator(event: "end", tabID: host?.tabID ?? UUID())
        changed()
        WindowManager.shared.saveSessionSoon()
    }
}
