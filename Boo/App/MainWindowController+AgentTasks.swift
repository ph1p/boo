import Cocoa
import SwiftUI

/// Agent tasks: a git worktree + branch per task, opened as its own workspace
/// with the agent already running. Merge or discard from the workspace's
/// context menu once the agent is done.
extension MainWindowController {
    /// The Agents setting "Setup command" (e.g. `pnpm install`) runs in a new task's
    /// worktree before its agent, in the same terminal so its output stays visible.
    /// `;`, not `&&`: a failed install still starts the agent, which can fix it.
    static func withTaskSetup(
        _ command: String,
        setup: String = AppSettings.shared.pluginString("agents", "taskSetup", default: "")
    ) -> String {
        let setup = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        return setup.isEmpty ? command : "\(setup); \(command)"
    }

    /// The variable a launched agent reads its first prompt from. The shell
    /// then echoes `claude "$_BOO_PROMPT"` instead of the whole prompt.
    /// Not `BOO_*`: a launch spec's env drops those.
    static let promptEnvKey = "_BOO_PROMPT"

    /// How a new terminal starts `kind` with `prompt`: a short command, and
    /// the prompt in the environment. With `setup`, the task setup command runs first.
    static func agentLaunch(
        kind: AgentKind, prompt: String, model: String? = nil, setup: Bool = false
    ) -> LaunchSpec {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = agentCommand(
            kind: kind, model: model, promptArgument: prompt.isEmpty ? nil : "\"$\(promptEnvKey)\"")
        if setup { command = withTaskSetup(command) }
        return LaunchSpec(command: command, env: prompt.isEmpty ? [:] : [promptEnvKey: prompt])
    }

    private static func agentCommand(kind: AgentKind, model: String?, promptArgument: String?) -> String {
        // `.custom` has no CLI of its own: it starts Claude Code.
        let adapter = kind.adapter ?? ClaudeCodeAdapter()
        return adapter.command(.start(model: model), prompt: promptArgument)
    }

    /// A started task: its worktree, workspace and the tab the agent runs in.
    struct AgentTaskLaunch {
        let info: AgentWorktree.Info
        let workspaceID: UUID
        let tabID: UUID?
    }

    // MARK: - New task

    /// Where a new task looks for its repository: the active tab's cwd first
    /// (the workspace folder is often `~` or a parent of the repo), then the
    /// workspace folder unless the cwd is inside it (git would fail there too).
    /// Never empty.
    private var agentTaskCandidateFolders: [String] {
        guard let workspace = activeWorkspace else { return [AppSettings.shared.defaultFolder] }
        let folder = workspace.folderPath
        guard let cwd = workspace.activeWorkingDirectory.map({ ($0 as NSString).expandingTildeInPath }) else {
            return [folder]
        }
        return cwd == folder || cwd.hasPrefix(folder + "/") ? [cwd] : [cwd, folder]
    }

    /// Main checkout of the first folder that is inside a git repository.
    /// Blocks; call off the main thread.
    nonisolated private static func agentTaskRepo(in folders: [String]) -> String? {
        folders.lazy.filter { FileManager.default.fileExists(atPath: $0) }.compactMap(AgentWorktree.mainRoot(of:)).first
    }

    @objc func newAgentTaskAction(_ sender: Any?) {
        let folders = agentTaskCandidateFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let root = Self.agentTaskRepo(in: folders)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let root else {
                    self.showAgentTaskError(
                        "\((folders[0] as NSString).abbreviatingWithTildeInPath) is not a git repository.",
                        title: "Can't Start Agent Task")
                    return
                }
                self.promptForAgentTask(repo: root)
            }
        }
    }

    private func promptForAgentTask(repo: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New Agent Task"
        alert.informativeText =
            "Creates a branch and worktree of \((repo as NSString).lastPathComponent) and starts the agent in a new workspace."

        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Task name, e.g. fix login redirect"
        let promptField = NSTextField(string: "")
        promptField.placeholderString = "First message to the agent (optional)"
        let agentPopup = NSPopUpButton()
        for kind in AgentKind.taskKinds { agentPopup.addItem(withTitle: kind.displayName) }
        for field in [nameField, promptField] { field.widthAnchor.constraint(equalToConstant: 320).isActive = true }

        let stack = NSStackView(views: [nameField, promptField, agentPopup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let prompt = promptField.stringValue
            var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = AgentCrew.shortName(prompt) }
            let kind = AgentKind.taskKinds[max(0, agentPopup.indexOfSelectedItem)]
            self.startAgentTask(repo: repo, name: name, kind: kind, prompt: prompt) { result in
                if case .failure(let error) = result {
                    self.showAgentTaskError(error.localizedDescription, title: "Can't Start Agent Task")
                }
            }
        }
    }

    /// Creates the worktree off the main thread (branching from `base`, default
    /// HEAD), then opens its workspace with the agent running.
    func startAgentTask(
        repo: String, name: String, kind: AgentKind, prompt: String, base: String? = nil, model: String? = nil,
        caller: UUID? = nil,
        completion: @escaping @MainActor (Result<AgentTaskLaunch, Error>) -> Void = { _ in }
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AgentWorktree.create(repo: repo, name: name, base: base) }
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    AgentWorktree.recordAgentKind(kind, in: info.path)
                    NotificationCenter.default.post(name: .agentWorktreesChanged, object: nil)
                    guard let self else { return }
                    let title = name.isEmpty ? (info.path as NSString).lastPathComponent : name
                    let spec = Self.agentLaunch(kind: kind, prompt: prompt, model: model, setup: true)
                    if let caller, let launch = self.openTaskBesideCaller(caller, info: info, launch: spec) {
                        completion(.success(launch))
                        return
                    }
                    let workspace = self.openWorkspace(path: info.path, name: title, initialLaunch: spec)
                    let tabID = workspace.pane(for: workspace.activePaneID)?.tabs.last?.id
                    completion(.success(AgentTaskLaunch(info: info, workspaceID: workspace.id, tabID: tabID)))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Opens a task in the caller's workspace, as a tab in the caller's crew
    /// (see `openHelperTab`), so a crew stays together instead of a new workspace.
    /// Nil when the caller is gone or its pane belongs to tmux.
    private func openTaskBesideCaller(
        _ callerTab: UUID, info: AgentWorktree.Info, launch: LaunchSpec
    ) -> AgentTaskLaunch? {
        guard let home = AgentInbox.locateInWindows(callerTab), home.controller === self, !home.pane.tmuxOwned,
            let opened = openHelperTab(
                caller: callerTab, in: home.workspace, callerPane: home.pane.id, cwd: info.path, launch: launch)
        else { return nil }
        return AgentTaskLaunch(info: info, workspaceID: home.workspace.id, tabID: opened.tabID)
    }

    /// A helper opens as a tab in the caller's pane, in the caller's crew group
    /// (right after the caller and earlier helpers). The tab shown before stays
    /// shown and focus stays where it is. A tmux pane can't hold it: split instead.
    func openHelperTab(
        caller: UUID, in workspace: Workspace, callerPane: UUID, cwd: String, launch: LaunchSpec
    ) -> (paneID: UUID, tabID: UUID)? {
        guard let pane = workspace.pane(for: callerPane), !pane.tmuxOwned,
            let paneView = workspacePaneViews[workspace.id]?[callerPane]
        else {
            return splitHelperPane(callerPane, in: workspace, cwd: cwd, launch: launch)
        }
        guard let tabID = addTabBehindShown(in: paneView, workingDirectory: cwd, launch: launch) else { return nil }
        pane.joinCrew(helper: tabID, parent: caller)
        paneView.groupsChanged()
        saveSession()
        return (callerPane, tabID)
    }

    /// Starts `kind` in a new terminal tab of `paneView` (default: the active
    /// pane) with `prompt` as its first message. The tab starts behind the shown
    /// one and comes forward once the agent runs, so the shell typing the
    /// command never shows.
    @discardableResult
    func startAgentTab(
        kind: AgentKind, prompt: String, workingDirectory: String, in paneView: PaneView? = nil, group: UUID? = nil
    ) -> UUID? {
        guard AppSettings.shared.agentsEnabled, let workspace = activeWorkspace,
            let pv = paneView ?? paneViews[workspace.activePaneID]
        else { return nil }
        guard
            let tabID = addTabBehindShown(
                in: pv, workingDirectory: workingDirectory, launch: Self.agentLaunch(kind: kind, prompt: prompt),
                group: group ?? pv.activeGroupID)
        else { return nil }
        revealAgentTab(tabID, in: pv, workspaceID: workspace.id)
        return tabID
    }

    /// Adds a terminal tab that starts as the active tab (so its terminal
    /// starts), then steps back behind the tab shown before. Focus stays put.
    private func addTabBehindShown(
        in pv: PaneView, workingDirectory: String, launch: LaunchSpec, group: UUID? = nil
    ) -> UUID? {
        let shown = pv.pane.activeTab?.id
        guard let tabID = pv.addNewTab(workingDirectory: workingDirectory, launch: launch, group: group, focus: false)
        else { return nil }
        if let shown, shown != tabID, let index = pv.pane.tabs.firstIndex(where: { $0.id == shown }) {
            pv.activateTab(index, focus: false)
        }
        return tabID
    }

    /// Brings `tabID` forward once its shell started the agent (Boo's shell
    /// integration reports the command), or after a second without it.
    private func revealAgentTab(_ tabID: UUID, in pv: PaneView, workspaceID: UUID) {
        let reveal: (TimeInterval) -> Void = { [weak self, weak pv] delay in
            // A moment for the agent to draw over the echoed command line.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let pv, let index = pv.pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.focusActivity(workspaceID: workspaceID, paneID: pv.pane.id, tabIndex: index)
            }
        }
        guard pv.terminalView(forTab: tabID)?.commandHistory.last == nil else { return reveal(0.15) }
        // Fired by `paneView(_:commandStarted:paneID:tabID:)`.
        pendingReveals[tabID] = { reveal(0.15) }
        // The shell may lack Boo's integration and never report: show it anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pendingReveals.removeValue(forKey: tabID)?()
        }
    }

    /// Splits `anchor` to the right for a helper, leaving focus where it is.
    private func splitHelperPane(
        _ anchor: UUID, in workspace: Workspace, cwd: String, launch: LaunchSpec
    ) -> (paneID: UUID, tabID: UUID)? {
        guard let paneID = splitPane(anchor, in: workspace, toward: .right, focus: false, cwd: cwd, launch: launch),
            let tabID = workspace.pane(for: paneID)?.activeTab?.id
        else { return nil }
        return (paneID, tabID)
    }

    /// An agent that starts a task keeps the user's attention: once the task's
    /// terminal has started, the window goes back to the caller's workspace,
    /// unless the user moved elsewhere meanwhile. The crew sidebar shows the task.
    private func returnToCaller(_ callerTab: UUID, from taskWorkspace: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.activeWorkspace?.id == taskWorkspace,
                let home = AgentInbox.locateInWindows(callerTab), home.controller === self,
                home.workspace.id != taskWorkspace,
                let index = self.appState.workspaces.firstIndex(where: { $0.id == home.workspace.id })
            else { return }
            self.activateWorkspace(index)
        }
    }

    /// `new_agent_task {name?, prompt?, agent?, repo?, base?, model?}`: repo
    /// defaults to the active workspace's repository; agent is an `AgentKind.ipcName`
    /// (default claude). The caller (by `token`) owns the new agent's tab.
    func ipcNewAgentTask(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let name = (json["name"] as? String) ?? ""
        let prompt = (json["prompt"] as? String) ?? ""
        guard !name.isEmpty || !prompt.isEmpty else {
            reply(["ok": false, "error": "missing name or prompt"])
            return
        }
        guard let kind = AgentKind(ipcName: (json["agent"] as? String) ?? "claude") else {
            reply(["ok": false, "error": "agent must be one of " + AgentKind.ipcNameList])
            return
        }
        let caller = CapabilityTokens.shared.resolve(json["token"] as? String)
        if json["worktree"] as? Bool == false {
            ipcNewHelperAgent(json: json, kind: kind, name: name, prompt: prompt, caller: caller, reply: reply)
            return
        }
        let explicitRepo = (json["repo"] as? String).map { ($0 as NSString).expandingTildeInPath }
        guard activeWorkspace != nil || explicitRepo != nil else {
            reply(["ok": false, "error": "missing repo"])
            return
        }
        // An explicit repo is passed through so create() reports its own error;
        // otherwise pick the first candidate folder that is in a repository.
        let folders = agentTaskCandidateFolders
        let title = name.isEmpty ? AgentCrew.shortName(prompt) : name
        let base = json["base"] as? String
        let model = json["model"] as? String
        Task { @MainActor [weak self] in
            let repo =
                if let explicitRepo { explicitRepo } else {
                    await Task.detached(priority: .userInitiated) { Self.agentTaskRepo(in: folders) }.value
                        ?? folders[0]
                }
            self?.startAgentTask(
                repo: repo, name: title, kind: kind, prompt: prompt, base: base, model: model,
                caller: caller?.tabID
            ) { result in
                switch result {
                case .failure(let error):
                    reply(["ok": false, "error": error.localizedDescription])
                case .success(let launch):
                    // Owned before the reply, so the caller's next write needs no approval.
                    if let caller, let tabID = launch.tabID {
                        CapabilityTokens.shared.markOwned(tabID, by: caller.tabID)
                        AgentCrew.shared.link(child: tabID, parent: caller.tabID, name: title)
                        if caller.tabID == OrchestratorController.shared.tabID {
                            OrchestratorController.shared.recordOwnedWorktree(launch.info.path)
                        }
                        self?.returnToCaller(caller.tabID, from: launch.workspaceID)
                    }
                    let task: [String: Any] = [
                        "tab_id": launch.tabID?.uuidString ?? NSNull(),
                        "handle": launch.tabID.map { AgentCrew.shared.handle(for: $0) } ?? NSNull(),
                        "workspace_id": launch.workspaceID.uuidString,
                        "path": launch.info.path, "branch": launch.info.branch ?? NSNull(),
                        "name": title, "agent": json["agent"] as? String ?? "claude"
                    ]
                    OrchestratorEvents.shared.post("task_spawned", task)
                    reply(task.merging(["ok": true]) { $1 })
                }
            }
        }
    }

    /// `new_agent_task {worktree: false}`: a helper agent in a pane beside the
    /// caller, in the caller's folder (or `cwd`), for work that needs no branch
    /// of its own: reviews, test runs, questions. Focus stays with the caller.
    func ipcNewHelperAgent(
        json: [String: Any], kind: AgentKind, name: String, prompt: String,
        caller: CapabilityTokens.Caller?, reply: @escaping ([String: Any]) -> Void
    ) {
        let location = caller.flatMap { AgentInbox.locateInWindows($0.tabID) }
        guard let workspace = location?.workspace ?? activeWorkspace else {
            reply(["ok": false, "error": "no workspace"])
            return
        }
        let anchor = location?.pane.id ?? workspace.activePaneID
        let cwd =
            (json["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
            ?? location.map { $0.pane.tabs[$0.tabIndex].workingDirectory } ?? workspace.folderPath
        let launch = Self.agentLaunch(kind: kind, prompt: prompt, model: json["model"] as? String)
        let opened =
            if let caller, location != nil {
                openHelperTab(caller: caller.tabID, in: workspace, callerPane: anchor, cwd: cwd, launch: launch)
            } else {
                splitHelperPane(anchor, in: workspace, cwd: cwd, launch: launch)
            }
        guard let (paneID, tabID) = opened else {
            reply(["ok": false, "error": "could not open a pane for the helper"])
            return
        }
        let title = name.isEmpty ? AgentCrew.shortName(prompt) : name
        if let caller {
            CapabilityTokens.shared.markOwned(tabID, by: caller.tabID)
            AgentCrew.shared.link(child: tabID, parent: caller.tabID, name: title)
        }
        let task: [String: Any] = [
            "tab_id": tabID.uuidString, "handle": AgentCrew.shared.handle(for: tabID),
            "pane_id": paneID.uuidString, "workspace_id": workspace.id.uuidString, "path": cwd,
            "name": title, "agent": json["agent"] as? String ?? "claude"
        ]
        OrchestratorEvents.shared.post("task_spawned", task)
        reply(task.merging(["ok": true]) { $1 })
    }

    /// Closes a helper agent's tab without asking, because the tab that started
    /// it closed. The last tab takes its pane, the last pane its workspace; a
    /// worktree stays on disk either way.
    func closeHelperTab(_ tabID: UUID) {
        guard let location = AgentInbox.locateInWindows(tabID), location.controller === self,
            let workspaceIndex = appState.workspaces.firstIndex(where: { $0 === location.workspace })
        else { return }
        let workspace = location.workspace
        let pane = location.pane
        let index = location.tabIndex
        let isActive = workspace === activeWorkspace
        if pane.tabs.count > 1 {
            notifyTerminalClosed(for: tabID)
            if let pv = workspacePaneViews[workspace.id]?[pane.id] {
                pv.closeTab(at: index)
            } else {
                pane.removeTab(at: index)
            }
        } else if workspace.splitTree.leafCount > 1 {
            if isActive {
                let focused = workspace.activePaneID
                workspace.activePaneID = pane.id
                closePaneAction(nil)
                if focused != pane.id, workspace.pane(for: focused) != nil { workspace.activePaneID = focused }
            } else {
                notifyTerminalClosed(for: pane.tabs)
                bridge.monitor.untrack(paneID: pane.id)
                workspacePaneViews[workspace.id]?.removeValue(forKey: pane.id)?.stopAll()
                _ = workspace.closePane(pane.id)
            }
        } else {
            forceCloseWorkspace(at: workspaceIndex)
            return
        }
        refreshStatusBar()
        saveSession()
    }

    // MARK: - Merge / discard

    /// Merge and Discard for workspaces whose folder is a linked worktree.
    func agentTaskMenuItems(forWorkspaceAt index: Int) -> [NSMenuItem] {
        guard index >= 0, index < appState.workspaces.count else { return [] }
        let workspace = appState.workspaces[index]
        guard AgentWorktree.looksLikeWorktree(workspace.folderPath) else { return [] }
        let review = NSMenuItem(
            title: "Review Changes...", action: #selector(reviewAgentTaskAction(_:)), keyEquivalent: "")
        let merge = NSMenuItem(
            title: "Merge Worktree...", action: #selector(mergeAgentTaskAction(_:)), keyEquivalent: "")
        let discard = NSMenuItem(
            title: "Discard Worktree...", action: #selector(discardAgentTaskAction(_:)), keyEquivalent: "")
        for item in [review, merge, discard] {
            item.target = self
            item.representedObject = workspace.id
        }
        return [review, merge, discard]
    }

    @objc func mergeAgentTaskAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        mergeAgentTask(workspaceID: id)
    }

    @objc func discardAgentTaskAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        discardAgentTask(workspaceID: id)
    }

    @objc func reviewAgentTaskAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openReview(workspaceID: id)
    }

    func mergeAgentTask(workspaceID: UUID) {
        guard let folder = appState.workspace(withID: workspaceID)?.folderPath else { return }
        // The full check (conflicts, a dirty main checkout) before asking, like `boo merge`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = AgentWorktree.info(for: folder)
            let check = info.map(AgentWorktree.mergeCheck(of:))
            DispatchQueue.main.async {
                guard let self, let workspace = self.appState.workspace(withID: workspaceID)
                else { return }
                guard let info, let check else {
                    self.showAgentTaskError("\(workspace.displayName) is not a git worktree.", title: "Not a Worktree")
                    return
                }
                self.confirmMerge(workspace: workspace, info: info, check: check)
            }
        }
    }

    func discardAgentTask(workspaceID: UUID) {
        withAgentTask(workspaceID: workspaceID) { [weak self] workspace, info, status in
            self?.confirmDiscard(workspace: workspace, info: info, status: status)
        }
    }

    /// Reads the worktree's git state off the main thread, then calls back on main.
    private func withAgentTask(
        workspaceID: UUID, _ body: @escaping @MainActor (Workspace, AgentWorktree.Info, AgentWorktree.Status) -> Void
    ) {
        guard let workspace = appState.workspace(withID: workspaceID) else { return }
        let folder = workspace.folderPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = AgentWorktree.info(for: folder)
            let status = info.map(AgentWorktree.status(of:))
            DispatchQueue.main.async {
                guard let self,
                    let workspace = self.appState.workspace(withID: workspaceID)
                else { return }
                guard let info, let status else {
                    self.showAgentTaskError("\(workspace.displayName) is not a git worktree.", title: "Not a Worktree")
                    return
                }
                body(workspace, info, status)
            }
        }
    }

    private func confirmMerge(workspace: Workspace, info: AgentWorktree.Info, check: AgentWorktree.MergeCheck) {
        guard let window else { return }
        let status = check.status
        let branch = info.branch ?? "The worktree"
        let target = status.target ?? "the main checkout"
        let cantMerge = "Can't Merge \(workspace.displayName)"
        let refusal: (message: String, title: String)? =
            switch check.blocker {
            case "no_target": ("The worktree or the main checkout is not on a branch.", cantMerge)
            case "dirty": ("\(branch) has uncommitted changes. Commit them first (or ask the agent to).", cantMerge)
            case "target_dirty":
                (
                    "\((info.mainRoot as NSString).abbreviatingWithTildeInPath) has uncommitted changes. "
                        + "Commit or stash them first.", cantMerge
                )
            case "conflicts":
                (
                    "\(branch) conflicts with \(target) in \((check.conflicts ?? []).joined(separator: ", ")). "
                        + "Ask the agent to rebase onto \(target).", cantMerge
                )
            case "nothing_to_merge": ("\(branch) has no commits that \(target) lacks.", "Nothing to Merge")
            default: nil
            }
        if let refusal {
            showAgentTaskError(refusal.message, title: refusal.title)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(status.ahead) commit\(status.ahead == 1 ? "" : "s") from \(branch) into \(target)?"
        var details = "Runs git merge --no-ff in \((info.mainRoot as NSString).abbreviatingWithTildeInPath)."
        let working = isAgentWorking(inWorkspace: workspace.id)
        if working {
            details = "The agent is still working: commits it makes after this are not merged.\n\n" + details
            alert.alertStyle = .warning
        }
        alert.informativeText = details
        let cleanup = NSButton(
            checkboxWithTitle: "Then remove the worktree and close the workspace", target: nil, action: nil)
        // Closing would stop a working agent and delete what it has not committed yet.
        cleanup.state = working ? .off : .on
        alert.accessoryView = cleanup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        let workspaceID = workspace.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let removeAfter = cleanup.state == .on
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try AgentWorktree.merge(info) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if case .failure(let error) = result {
                        self.showAgentTaskError(error.localizedDescription, title: "Merge Failed")
                        return
                    }
                    if removeAfter { self.closeAndRemoveAgentTask(workspaceID: workspaceID, info: info) }
                }
            }
        }
    }

    /// What discarding a task does and loses, e.g. "Closes the workspace and
    /// deletes the worktree and branch x, losing 2 unmerged commits."
    static func discardSummary(
        info: AgentWorktree.Info, status: AgentWorktree.Status
    ) -> (text: String, losesWork: Bool) {
        var losses: [String] = []
        if status.ahead > 0 { losses.append("\(status.ahead) unmerged commit\(status.ahead == 1 ? "" : "s")") }
        if status.isDirty { losses.append("uncommitted changes") }
        let text =
            "Closes the workspace and deletes the worktree"
            + (info.branch.map { " and branch \($0)" } ?? "")
            + (losses.isEmpty ? "." : ", losing \(losses.joined(separator: " and ")).")
        return (text, !losses.isEmpty)
    }

    /// The discard summary for an inline confirmation (the crew sidebar).
    func agentTaskDiscardSummary(workspaceID: UUID, completion: @escaping @MainActor (String, Bool) -> Void) {
        withAgentTask(workspaceID: workspaceID) { _, info, status in
            let summary = Self.discardSummary(info: info, status: status)
            completion(summary.text, summary.losesWork)
        }
    }

    /// Discards without asking: the caller already confirmed.
    func discardAgentTaskConfirmed(workspaceID: UUID) {
        withAgentTask(workspaceID: workspaceID) { [weak self] _, info, _ in
            self?.closeAndRemoveAgentTask(workspaceID: workspaceID, info: info)
        }
    }

    private func confirmDiscard(workspace: Workspace, info: AgentWorktree.Info, status: AgentWorktree.Status) {
        guard let window else { return }
        let summary = Self.discardSummary(info: info, status: status)
        let alert = NSAlert()
        alert.messageText = "Discard \(workspace.displayName)?"
        alert.informativeText = summary.text
        alert.alertStyle = summary.losesWork ? .warning : .informational
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = summary.losesWork
        let workspaceID = workspace.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeAndRemoveAgentTask(workspaceID: workspaceID, info: info)
        }
    }

    /// Closes the workspace first (its shells hold the folder), then deletes
    /// the worktree and branch.
    /// Closes the task's UI and deletes its worktree. A task opened beside its
    /// caller lives in a tab (`tabID`) of a shared workspace: close only that tab.
    func closeAndRemoveAgentTask(workspaceID: UUID, info: AgentWorktree.Info, tabID: UUID? = nil) {
        if let index = appState.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            let ownsWorkspace = AgentWorktree.standardized(appState.workspaces[index].folderPath) == info.path
            if let tabID, !ownsWorkspace {
                closeHelperTab(tabID)
            } else {
                forceCloseWorkspace(at: index)
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Result(catching: { try AgentWorktree.remove(info, deleteBranch: true) })
            DispatchQueue.main.async { NotificationCenter.default.post(name: .agentWorktreesChanged, object: nil) }
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    // The window may be gone when this was its last workspace.
                    let controller = WindowManager.shared.activeController
                    controller?.showAgentTaskError(error.localizedDescription, title: "Couldn't Remove Worktree")
                }
            }
        }
    }

    func showAgentTaskError(_ message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Review

    @objc func reviewChangesAction(_ sender: Any?) {
        guard let id = activeWorkspace?.id else { return }
        openReview(workspaceID: id)
    }

    /// Opens (or focuses) the review tab for a workspace, in its active pane.
    @discardableResult
    func openReview(workspaceID: UUID) -> Bool {
        guard let index = appState.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        if index != appState.activeWorkspaceIndex { activateWorkspace(index) }
        let workspace = appState.workspaces[index]
        let title = "Review: \(workspace.displayName)"
        if let pane = workspace.pane(for: workspace.activePaneID),
            let tabIndex = pane.tabs.firstIndex(where: { $0.contentType == .pluginView && $0.title == title })
        {
            focusActivity(workspaceID: workspaceID, paneID: pane.id, tabIndex: tabIndex)
            return true
        }
        guard let paneView = paneViews[workspace.activePaneID] else { return false }
        let model = AgentReviewModel(workspaceID: workspaceID, folder: workspace.folderPath)
        paneView.addPluginViewTab(
            view: AnyView(AgentReviewView(model: model)), title: title, icon: "checklist",
            workingDirectory: workspace.folderPath)
        model.reload()
        return true
    }

    /// Opens the diff viewer on a repository's unstaged or staged changes with
    /// `path` (relative to the repository root) selected. A tab already showing
    /// them in the active workspace is reused and reloaded.
    @discardableResult
    func openDiff(repoRoot: String, source: AgentReview.Source, path: String?) -> Bool {
        guard let workspace = appState.activeWorkspace else { return false }
        let repo = (repoRoot as NSString).lastPathComponent
        let title = source == .staged ? "Staged: \(repo)" : "Changes: \(repo)"
        if let model = AgentReviewModel.existing(folder: repoRoot, source: source),
            model.workspaceID == workspace.id,
            let pane = workspace.panes.values.first(where: { pane in
                pane.tabs.contains { $0.contentType == .pluginView && $0.title == title }
            }),
            let tabIndex = pane.tabs.firstIndex(where: { $0.contentType == .pluginView && $0.title == title })
        {
            if let path { model.selectedPath = path }
            model.reload()
            focusActivity(workspaceID: workspace.id, paneID: pane.id, tabIndex: tabIndex)
            return true
        }
        guard let paneView = paneViews[workspace.activePaneID] else { return false }
        let model = AgentReviewModel(workspaceID: workspace.id, folder: repoRoot, source: source, selectedPath: path)
        paneView.addPluginViewTab(
            view: AnyView(AgentReviewView(model: model)), title: title, icon: "plus.forwardslash.minus",
            workingDirectory: repoRoot)
        model.reload()
        return true
    }

    /// The tab the workspace's agent runs in: one the inbox knows about, else
    /// the first terminal tab (agent tasks start the agent there).
    func agentTab(inWorkspace workspaceID: UUID) -> (paneID: UUID, tabIndex: Int)? {
        guard let workspace = appState.workspace(withID: workspaceID) else { return nil }
        for item in AgentInbox.shared.sortedItems {
            if let location = AgentInbox.shared.locate(item.tabID), location.workspace.id == workspaceID {
                return (location.pane.id, location.tabIndex)
            }
        }
        let panes = [workspace.activePaneID] + workspace.panes.keys.filter { $0 != workspace.activePaneID }
        for paneID in panes {
            if let pane = workspace.pane(for: paneID),
                let tabIndex = pane.tabs.firstIndex(where: { $0.contentType == .terminal })
            {
                return (paneID, tabIndex)
            }
        }
        return nil
    }

    /// Switches to the agent's tab and submits `text` as its next prompt. With
    /// no agent running there (a stopped task after a quit or restart), the tab
    /// is a plain shell: it resumes the agent with `text` instead of running
    /// the text as shell commands.
    /// The text goes into the tab's terminal before the tab comes forward, so
    /// the user sees it arrive whole instead of watching it being typed.
    @discardableResult
    func sendToAgent(workspaceID: UUID, text: String) -> Bool {
        guard let target = agentTab(inWorkspace: workspaceID) else { return false }
        let input =
            hasLiveAgent(inWorkspace: workspaceID)
            ? text : Self.resumeCommand(kind: taskAgentKind(workspaceID), text: text)
        return submit(input, toTab: target, inWorkspace: workspaceID)
    }

    /// Submits `input` in the tab's terminal, then shows the tab. A tab never
    /// shown since launch has no terminal yet: it is shown first so one starts.
    private func submit(
        _ input: String, toTab target: (paneID: UUID, tabIndex: Int), inWorkspace workspaceID: UUID
    ) -> Bool {
        if let view = backgroundTerminal(workspaceID: workspaceID, paneID: target.paneID, tabIndex: target.tabIndex) {
            view.paste(input, submit: true)
            focusActivity(workspaceID: workspaceID, paneID: target.paneID, tabIndex: target.tabIndex)
            return true
        }
        focusActivity(workspaceID: workspaceID, paneID: target.paneID, tabIndex: target.tabIndex)
        guard let view = ghosttyView(for: target.paneID) else { return false }
        view.paste(input, submit: true)
        return true
    }

    /// The live terminal of a tab, shown or not.
    private func backgroundTerminal(workspaceID: UUID, paneID: UUID, tabIndex: Int) -> GhosttyView? {
        guard let workspace = appState.workspace(withID: workspaceID),
            let pane = workspace.pane(for: paneID), pane.tabs.indices.contains(tabIndex)
        else { return nil }
        return workspacePaneViews[workspaceID]?[paneID]?.terminalView(forTab: pane.tabs[tabIndex].id)
    }

    /// Restarts a stopped task's agent in its tab, on its last conversation.
    @discardableResult
    func resumeAgentTask(workspaceID: UUID) -> Bool {
        guard !hasLiveAgent(inWorkspace: workspaceID), let target = agentTab(inWorkspace: workspaceID) else {
            return false
        }
        return submit(
            Self.resumeCommand(kind: taskAgentKind(workspaceID), text: nil), toTab: target, inWorkspace: workspaceID)
    }

    /// The agent the workspace's task started with (Claude Code for tasks made
    /// before Boo recorded it).
    private func taskAgentKind(_ workspaceID: UUID) -> AgentKind {
        guard let workspace = appState.workspace(withID: workspaceID) else { return .claudeCode }
        return AgentWorktree.agentKind(in: workspace.folderPath) ?? .claudeCode
    }

    /// `claude --continue` picks up the newest conversation in the worktree's
    /// folder, so the agent keeps what it did before it stopped.
    static func resumeCommand(kind: AgentKind = .claudeCode, text: String?) -> String {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let adapter = kind.adapter ?? ClaudeCodeAdapter()
        return adapter.command(.continueLast, prompt: text.isEmpty ? nil : shellEscape(text))
    }

    private func isAgentWorking(inWorkspace workspaceID: UUID) -> Bool {
        hasLiveAgent(inWorkspace: workspaceID) { $0.state == .working }
    }

    private func hasLiveAgent(
        inWorkspace workspaceID: UUID, where match: (AgentInbox.Item) -> Bool = { _ in true }
    ) -> Bool {
        AgentInbox.shared.sortedItems.contains {
            match($0) && AgentInbox.shared.locate($0.tabID)?.workspace.id == workspaceID
        }
    }

    @objc func jumpToNextWaitingAgentAction(_ sender: Any?) {
        AgentInbox.shared.jumpToNextAttention()
    }

    @objc func jumpToLastFinishedAgentAction(_ sender: Any?) {
        AgentInbox.shared.jumpToLastFinished()
    }
}

// MARK: - Context handoff

extension MainWindowController {
    /// Hands the active terminal's selection, or else its last command's output,
    /// to the nearest agent: one in this workspace, else the most recently active.
    @objc func sendContextToAgentAction(_ sender: Any?) {
        guard let view = activeGhosttyView else {
            NSSound.beep()
            return
        }
        guard let (source, captured) = view.selectionOrLastOutput() else {
            NSSound.beep()
            return
        }
        let cwd = view.tabID.flatMap(AgentHandoff.workingDirectory(ofTab:))
        let text = AgentHandoff.compose(captured, source: source, cwd: cwd)
        guard let target = AgentHandoff.targets(excluding: view.tabID).first,
            AgentHandoff.send(text, to: target.tabID)
        else {
            NSSound.beep()
            return
        }
    }
}
