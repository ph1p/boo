import Cocoa
import SwiftUI

/// Agent tasks: a git worktree + branch per task, opened as its own workspace
/// with the agent already running. Merge or discard from the workspace's
/// context menu once the agent is done.
extension MainWindowController {
    /// Agents a task can start with.
    static let agentTaskKinds: [AgentKind] = [.claudeCode, .codex, .openCode]

    /// Shell command that starts `kind`, passing `prompt` as the first message.
    static func agentTaskCommand(kind: AgentKind, prompt: String) -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        switch kind {
        case .claudeCode, .custom: base = "claude"
        case .codex: base = "codex"
        case .openCode: base = prompt.isEmpty ? "opencode" : "opencode --prompt"
        }
        guard !prompt.isEmpty else { return base }
        // Always quote: a bare word prompt could still be read as a subcommand.
        return base + " '" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - New task

    @objc func newAgentTaskAction(_ sender: Any?) {
        let folder = activeWorkspace?.folderPath ?? AppSettings.shared.defaultFolder
        DispatchQueue.global(qos: .userInitiated).async {
            let root = AgentWorktree.info(for: folder)?.mainRoot ?? AgentWorktree.repoRoot(of: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let root else {
                    self.showAgentTaskError(
                        "\((folder as NSString).abbreviatingWithTildeInPath) is not a git repository.",
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
        for kind in Self.agentTaskKinds { agentPopup.addItem(withTitle: kind.displayName) }
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
            if name.isEmpty { name = String(prompt.prefix(40)) }
            let kind = Self.agentTaskKinds[max(0, agentPopup.indexOfSelectedItem)]
            self.startAgentTask(repo: repo, name: name, kind: kind, prompt: prompt) { error in
                if let error { self.showAgentTaskError(error, title: "Can't Start Agent Task") }
            }
        }
    }

    /// Creates the worktree off the main thread, then opens its workspace with
    /// the agent running. `completion` gets an error message or nil.
    func startAgentTask(
        repo: String, name: String, kind: AgentKind, prompt: String,
        completion: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AgentWorktree.create(repo: repo, name: name) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let info):
                    let title = name.isEmpty ? (info.path as NSString).lastPathComponent : name
                    self?.openWorkspace(
                        path: info.path, name: title,
                        initialCommand: Self.agentTaskCommand(kind: kind, prompt: prompt))
                    completion(nil)
                case .failure(let error):
                    completion(error.localizedDescription)
                }
            }
        }
    }

    /// `new_agent_task {name?, prompt?, agent?, repo?}`: repo defaults to the
    /// active workspace's repository; agent is claude (default), codex or opencode.
    func ipcNewAgentTask(json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let name = (json["name"] as? String) ?? ""
        let prompt = (json["prompt"] as? String) ?? ""
        guard !name.isEmpty || !prompt.isEmpty else {
            reply(["ok": false, "error": "missing name or prompt"])
            return
        }
        let kinds: [String: AgentKind] = ["claude": .claudeCode, "codex": .codex, "opencode": .openCode]
        guard let kind = kinds[(json["agent"] as? String) ?? "claude"] else {
            reply(["ok": false, "error": "agent must be claude, codex or opencode"])
            return
        }
        let repo = (json["repo"] as? String).map { ($0 as NSString).expandingTildeInPath }
        guard let repo = repo ?? activeWorkspace?.folderPath else {
            reply(["ok": false, "error": "missing repo"])
            return
        }
        let title = name.isEmpty ? String(prompt.prefix(40)) : name
        startAgentTask(repo: repo, name: title, kind: kind, prompt: prompt) { [weak self] error in
            if let error {
                reply(["ok": false, "error": error])
                return
            }
            let workspace = self?.activeWorkspace
            reply([
                "ok": true, "path": workspace?.folderPath ?? "",
                "workspace_id": workspace?.id.uuidString ?? ""
            ])
        }
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
        withAgentTask(workspaceID: workspaceID) { [weak self] workspace, info, status in
            self?.confirmMerge(workspace: workspace, info: info, status: status)
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
        guard let workspace = appState.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let folder = workspace.folderPath
        DispatchQueue.global(qos: .userInitiated).async {
            let info = AgentWorktree.info(for: folder)
            let status = info.map(AgentWorktree.status(of:))
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    let workspace = self.appState.workspaces.first(where: { $0.id == workspaceID })
                else { return }
                guard let info, let status else {
                    self.showAgentTaskError("\(workspace.displayName) is not a git worktree.", title: "Not a Worktree")
                    return
                }
                body(workspace, info, status)
            }
        }
    }

    private func confirmMerge(workspace: Workspace, info: AgentWorktree.Info, status: AgentWorktree.Status) {
        guard let window, let branch = info.branch, let target = status.target else {
            showAgentTaskError(
                "The worktree or the main checkout is not on a branch.", title: "Can't Merge \(workspace.displayName)")
            return
        }
        if status.isDirty {
            showAgentTaskError(
                "\(branch) has uncommitted changes. Commit them first (or ask the agent to).",
                title: "Can't Merge \(workspace.displayName)")
            return
        }
        guard status.ahead > 0 else {
            showAgentTaskError("\(branch) has no commits that \(target) lacks.", title: "Nothing to Merge")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(status.ahead) commit\(status.ahead == 1 ? "" : "s") from \(branch) into \(target)?"
        alert.informativeText = "Runs git merge --no-ff in \((info.mainRoot as NSString).abbreviatingWithTildeInPath)."
        let cleanup = NSButton(
            checkboxWithTitle: "Then remove the worktree and close the workspace", target: nil, action: nil)
        cleanup.state = .on
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

    private func confirmDiscard(workspace: Workspace, info: AgentWorktree.Info, status: AgentWorktree.Status) {
        guard let window else { return }
        var losses: [String] = []
        if status.ahead > 0 { losses.append("\(status.ahead) unmerged commit\(status.ahead == 1 ? "" : "s")") }
        if status.isDirty { losses.append("uncommitted changes") }
        let alert = NSAlert()
        alert.messageText = "Discard \(workspace.displayName)?"
        alert.informativeText =
            "Closes the workspace and deletes the worktree"
            + (info.branch.map { " and branch \($0)" } ?? "")
            + (losses.isEmpty ? "." : ", losing \(losses.joined(separator: " and ")).")
        alert.alertStyle = losses.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if !losses.isEmpty { alert.buttons.first?.hasDestructiveAction = true }
        let workspaceID = workspace.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeAndRemoveAgentTask(workspaceID: workspaceID, info: info)
        }
    }

    /// Closes the workspace first (its shells hold the folder), then deletes
    /// the worktree and branch.
    private func closeAndRemoveAgentTask(workspaceID: UUID, info: AgentWorktree.Info) {
        if let index = appState.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            forceCloseWorkspace(at: index)
        }
        DispatchQueue.global(qos: .utility).async {
            if case .failure(let error) = Result(catching: { try AgentWorktree.remove(info, deleteBranch: true) }) {
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
        let model = AgentReviewModel(workspaceID: workspaceID, folder: workspace.folderPath, controller: self)
        paneView.addPluginViewTab(view: AnyView(AgentReviewView(model: model)), title: title, icon: "checklist")
        model.reload()
        return true
    }

    /// The tab the workspace's agent runs in: one the inbox knows about, else
    /// the first terminal tab (agent tasks start the agent there).
    func agentTab(inWorkspace workspaceID: UUID) -> (paneID: UUID, tabIndex: Int)? {
        guard let workspace = appState.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
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

    /// Switches to the agent's tab and submits `text` as its next prompt.
    @discardableResult
    func sendToAgent(workspaceID: UUID, text: String) -> Bool {
        guard let target = agentTab(inWorkspace: workspaceID) else { return false }
        focusActivity(workspaceID: workspaceID, paneID: target.paneID, tabIndex: target.tabIndex)
        guard let view = ghosttyView(for: target.paneID) else { return false }
        view.paste(text, submit: true)
        return true
    }

    @objc func jumpToNextWaitingAgentAction(_ sender: Any?) {
        AgentInbox.shared.jumpToNextAttention()
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
        let cwd = view.tabID.flatMap(AgentHandoff.workingDirectory(ofTab:))
        let text: String
        if let selection = view.readSelectionText(), !selection.isEmpty {
            text = AgentHandoff.compose(selection, source: .selection, cwd: cwd)
        } else if let (source, output) = view.lastCommandOutput(), !output.isEmpty {
            text = AgentHandoff.compose(output, source: source, cwd: cwd)
        } else {
            NSSound.beep()
            return
        }
        guard let target = AgentHandoff.targets(excluding: view.tabID).first,
            AgentHandoff.send(text, to: target.tabID)
        else {
            NSSound.beep()
            return
        }
    }
}
