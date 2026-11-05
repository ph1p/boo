import AppKit
import SwiftUI

/// The Crew section: every agent in every window with its handle, grouped by
/// what it needs from the user, plus its actions.
extension AgentsPlugin {
    func startCrewObserving() {
        guard crewObservers.isEmpty else { return }
        for name in [Notification.Name.agentInboxChanged, .agentCrewChanged] {
            crewObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onRequestCycleRerun?() }
                })
        }
        crewObservers.append(
            NotificationCenter.default.addObserver(forName: .agentWorktreesChanged, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.worktreeScan.invalidate()
                    self.scanWorktrees(cwd: self.currentCwd)
                }
            })
    }

    static func crewRows(
        items: [AgentInbox.Item], crew: AgentCrew,
        isTask: (UUID) -> Bool = { tabID in
            AgentInbox.locateInWindows(tabID).map { AgentWorktree.looksLikeWorktree($0.workspace.folderPath) } ?? false
        },
        isReachable: (UUID) -> Bool = { AgentInbox.locateInWindows($0) != nil },
        workspace: (UUID) -> CrewWorkspace? = { crewWorkspace(of: $0) },
        taskStatus: (AgentInbox.Item) -> AgentTaskStatus.Summary? = { item in
            AgentInbox.locateInWindows(item.tabID).flatMap { location in
                let folder = location.workspace.folderPath
                guard AgentWorktree.looksLikeWorktree(folder) else { return nil }
                // A new state (a finished turn, a commit) asks git again.
                return AgentTaskStatus.shared.summary(for: folder, stamp: "\(item.state.rawValue)|\(item.updatedAt)")
            }
        }
    ) -> [AgentCrewRow] {
        // Oldest change first: a handle first issued here follows when the agent
        // showed up, not the inbox's dictionary order.
        items.sorted { ($0.updatedAt, $0.tabID.uuidString) < ($1.updatedAt, $1.tabID.uuidString) }.map { item in
            let fields = crew.fields(for: item.tabID)
            let detail: String? =
                switch item.state {
                case .working: item.tool.map { "using \($0)" }
                case .needsInput, .error: item.message
                case .done: item.reply ?? item.message
                }
            return AgentCrewRow(
                id: item.tabID, handle: fields["handle"] as? String ?? "",
                // Unnamed agents read "claude in api" like `boo agents`, so two of them differ.
                name: (fields["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? item.cwd.map { "\(item.agent) in \(($0 as NSString).lastPathComponent)" } ?? "",
                agent: item.agent, state: item.state,
                // One plain line: the first line of the answer, without markdown code ticks.
                detail: detail.map {
                    ($0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0).replacingOccurrences(
                        of: "`", with: "")
                },
                parent: fields["parent"] as? String, queued: fields["queued"] as? Int ?? 0,
                needsAttention: item.needsAttention, isTask: isTask(item.tabID),
                isReachable: isReachable(item.tabID), asksQuestion: item.asksQuestion,
                updatedAt: item.updatedAt.timeIntervalSince1970, taskStatus: taskStatus(item), folder: item.cwd,
                workspace: workspace(item.tabID))
        }.sorted { lhs, rhs in
            // Parents first, each helper right below the agent that started it.
            func order(_ row: AgentCrewRow) -> (Int, Int, String) {
                let own = Int(row.handle.dropFirst()) ?? 0
                return (
                    row.parent.flatMap { Int($0.dropFirst()) } ?? own, row.parent == nil ? 0 : own, row.id.uuidString
                )
            }
            return order(lhs) < order(rhs)
        }
    }

    /// Task workspaces under `~/.boo/worktrees` with no live agent in any tab,
    /// as stopped rows: after a restart the workspaces come back but the agents
    /// don't, and the work still needs a Review, Merge or Discard.
    static func stoppedTaskRows(
        workspaces: [Workspace], live: Set<UUID>, order: [UUID: Int] = workspaceOrder(),
        isTask: (String) -> Bool = { path in
            AgentWorktree.isUnderTaskRoot(path) && AgentWorktree.looksLikeWorktree(path)
        },
        taskStatus: (String) -> AgentTaskStatus.Summary? = { AgentTaskStatus.shared.summary(for: $0, stamp: "stopped") }
    ) -> [AgentCrewRow] {
        workspaces.compactMap { workspace in
            let tabs = workspace.panes.values.flatMap(\.tabs)
            guard isTask(workspace.folderPath), !tabs.contains(where: { live.contains($0.id) }),
                let tab = workspace.pane(for: workspace.activePaneID)?.tabs.first ?? tabs.first
            else { return nil }
            return AgentCrewRow(
                id: tab.id, handle: "", name: workspace.displayName, agent: "agent", state: .done,
                detail: "agent not running", parent: nil, queued: 0, needsAttention: false, isTask: true,
                isStopped: true, taskStatus: taskStatus(workspace.folderPath),
                workspace: crewWorkspace(workspace, order: order[workspace.id] ?? 0))
        }
    }

    /// Agents found by their process in a tab with no hooks reporting to Boo's
    /// inbox (started before the hooks were installed, or a CLI without them).
    static func unhookedRows(
        sessions: [(session: WorkspaceAgentSession, workspace: CrewWorkspace?)], hooked: Set<UUID>
    ) -> [AgentCrewRow] {
        sessions.filter { !hooked.contains($0.session.tabID) }.map { entry in
            let agent = entry.session.agent
            let state: AgentInbox.State =
                switch agent.state {
                case .running, .unknown: .working
                case .needsInput: .needsInput
                case .idle: .done
                }
            return AgentCrewRow(
                id: entry.session.tabID, handle: "",
                name: "\(agent.kind.displayName) in \((agent.cwd as NSString).lastPathComponent)",
                agent: agent.kind.ipcName, state: state, detail: nil, parent: nil, queued: 0,
                needsAttention: false, isTask: entry.workspace?.isTask == true,
                // No hook carries its prompt, so no Allow / Deny: the tab answers it.
                asksQuestion: true, folder: agent.cwd, workspace: entry.workspace, hasHooks: false)
        }
    }

    /// Where a tab is, as the crew list groups it; nil outside Boo's windows.
    static func crewWorkspace(of tabID: UUID, order: [UUID: Int]? = nil) -> CrewWorkspace? {
        guard let location = AgentInbox.locateInWindows(tabID) else { return nil }
        return crewWorkspace(location.workspace, order: (order ?? workspaceOrder())[location.workspace.id] ?? 0)
    }

    static func crewWorkspace(_ workspace: Workspace, order: Int) -> CrewWorkspace {
        CrewWorkspace(
            id: workspace.id, name: workspace.displayName,
            isTask: AgentWorktree.isUnderTaskRoot(workspace.folderPath), order: order,
            color: workspace.resolvedColor(theme: AppSettings.shared.theme))
    }

    /// Every workspace's position: windows in order, then each window's workspace bar.
    static func workspaceOrder() -> [UUID: Int] {
        var order: [UUID: Int] = [:]
        for workspace in WindowManager.shared.controllers.flatMap(\.appState.workspaces)
        where order[workspace.id] == nil {
            order[workspace.id] = order.count
        }
        return order
    }

    /// Agent sessions found by process in every workspace of every window.
    static func allAgentSessions(
        order: [UUID: Int] = workspaceOrder()
    ) -> [(session: WorkspaceAgentSession, workspace: CrewWorkspace?)] {
        WindowManager.shared.controllers.flatMap { controller in
            controller.appState.workspaces.flatMap { workspace in
                let crew = crewWorkspace(workspace, order: order[workspace.id] ?? 0)
                return controller.agentSessions(in: workspace).map { (session: $0, workspace: Optional(crew)) }
            }
        }
    }

    /// Live agents (with Boo's hooks or found by process), then stopped task
    /// workspaces, across every window.
    static func allCrewRows(
        order: [UUID: Int] = workspaceOrder(),
        sessions: [(session: WorkspaceAgentSession, workspace: CrewWorkspace?)]? = nil
    ) -> [AgentCrewRow] {
        let items = Array(AgentInbox.shared.items.values)
        let hooked = Set(items.map(\.tabID))
        // The orchestrator's tab reports through hooks too but is not a crew agent.
        let reported = hooked.union(AgentInbox.shared.orchestratorTabID().map { [$0] } ?? [])
        let unhooked = unhookedRows(sessions: sessions ?? allAgentSessions(order: order), hooked: reported)
        return crewRows(
            items: items, crew: AgentCrew.shared, workspace: { crewWorkspace(of: $0, order: order) }) + unhooked
            + stoppedTaskRows(
                workspaces: WindowManager.shared.controllers.flatMap(\.appState.workspaces),
                live: hooked.union(unhooked.map(\.id)), order: order)
    }

    /// The setting that lists only the active workspace's agents.
    static let activeOnlyKey = "crewActiveWorkspaceOnly"
    static var crewActiveOnly: Bool { AppSettings.shared.pluginBool("agents", activeOnlyKey, default: false) }

    func makeCrewSection(
        fontScale: SidebarFontScale, textColor: Color, mutedColor: Color, accentColor: Color
    ) -> SidebarSection? {
        startCrewObserving()
        // Shown with no agents too: it is where one is started. Without an
        // agent CLI the tab's own empty state says what to install.
        // One pass over the windows' workspaces per refresh, shared by every row.
        let order = Self.workspaceOrder()
        let agentSessions = Self.allAgentSessions(order: order)
        let rows = Self.allCrewRows(order: order, sessions: agentSessions)
        let activeID = actions?.activeWorkspaceID?()
        let activeOnly = Self.crewActiveOnly
        let agents = AgentKind.taskKinds.filter { installedAgents.contains($0) }
        guard !rows.isEmpty || !agents.isEmpty else { return nil }
        // Agent sessions by tab, for Timeline and Transcript.
        var sessions: [UUID: AgentSession] = [:]
        for entry in agentSessions { sessions[entry.session.tabID] = entry.session.agent }
        // Counts what needs the user everywhere, also in strict mode: a question
        // in another workspace still waits. An unread answer is not waiting.
        let waiting = rows.filter(AgentCrewView.needsYou).count
        let shown = activeOnly ? rows.filter { $0.workspace?.id == activeID }.count : rows.count
        let activeName = activeID.flatMap { id in
            WindowManager.shared.controllers.lazy.flatMap(\.appState.workspaces).first { $0.id == id }?.displayName
        }
        let startHere: (AgentKind, String) -> Void = { [weak self] kind, prompt in
            self?.startAgent(kind: kind, prompt: prompt)
        }
        let startTask: (String, AgentKind, @escaping @MainActor (String?) -> Void) -> Void = {
            prompt, agent, completion in Self.startTask(prompt: prompt, agent: agent, completion: completion)
        }
        let setActiveOnly: (Bool) -> Void = { AppSettings.shared.setPluginSetting("agents", Self.activeOnlyKey, $0) }
        return SidebarSection(
            id: "agents.crew",
            name: waiting > 0 ? "Agents (\(waiting) need you)" : shown == 0 ? "Agents" : "Agents (\(shown))",
            icon: "person.3",
            content: AnyView(
                AgentCrewView(
                    rows: rows, fontScale: fontScale, textColor: textColor, mutedColor: mutedColor,
                    accentColor: accentColor,
                    onJump: { Self.perform(.show, on: $0) },
                    onSend: { row, text in AgentCrew.shared.send(to: row.id, from: nil, text: text) },
                    onReview: { Self.perform(.review, on: $0) },
                    onMerge: { Self.perform(.merge, on: $0) },
                    onDiscardSummary: { row, completion in
                        Self.withTask(row) { controller, workspaceID in
                            controller.agentTaskDiscardSummary(workspaceID: workspaceID, completion: completion)
                        }
                    },
                    onDiscard: { row in
                        Self.withTask(row) { controller, workspaceID in
                            controller.discardAgentTaskConfirmed(workspaceID: workspaceID)
                        }
                    },
                    onStartTask: startTask,
                    agents: agents,
                    onStartHere: startHere,
                    onRespond: { row, response in Self.perform(response == .approve ? .allow : .deny, on: row) },
                    onResume: { Self.perform(.resume, on: $0) },
                    sessions: sessions,
                    onShowTimeline: { [weak self] _, session in
                        guard let id = session.sessionID else { return }
                        let folder = (session.cwd as NSString).lastPathComponent
                        self?.actions?.openAgentTimeline?(id, "\(session.kind.shortName) — \(folder)")
                    },
                    onOpenTranscript: { [weak self] path in
                        self?.actions?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                    },
                    activeWorkspaceID: activeID, activeWorkspaceName: activeName, activeOnly: activeOnly,
                    onShowAll: { setActiveOnly(false) },
                    onShowActiveOnly: { setActiveOnly(true) })),
            // Sized to its rows, so every agent shows without scrolling.
            prefersOuterScrollView: false,
            generation: SidebarSection.generation(
                for: rows.map(\.key) + installedAgents.map(\.rawValue).sorted()
                    + ["\(activeID?.uuidString ?? "")|\(activeName ?? "")|\(activeOnly)"]
                    + sessions.map { "\($0.key)=\($0.value.sessionID ?? "")" }.sorted()))
    }

    enum CrewAction: String {
        case show, message, resume, review, merge, discard, allow, deny
        case newTask = "new_task"
    }

    /// What the crew section's buttons and context menu do (also `debug_crew_action`).
    /// Message, new task and discard open their inline field or confirmation;
    /// with `text`, a message or new task is sent right away.
    static func perform(_ action: CrewAction, on row: AgentCrewRow?, text: String? = nil) {
        let ui = AgentCrewUIState.shared
        switch (action, row) {
        case (.newTask, _):
            if let text {
                startTask(prompt: text, agent: ui.taskAgent) { error in
                    if let error { booLog(.info, .sidebar, "crew start failed: \(error)") }
                }
            } else {
                ui.open(.newTask)
            }
        case (.show, let row?):
            ui.selection = row.id
            if row.hasHooks {
                AgentInbox.shared.jump(to: row.id)
            } else if let location = AgentInbox.locateInWindows(row.id) {
                // Not in the inbox: jump(to:) would find nothing.
                AgentInbox.focus(location)
            }
        case (.message, let row?) where row.hasHooks:
            if let text { AgentCrew.shared.send(to: row.id, from: nil, text: text) } else { ui.open(.message(row.id)) }
        case (.resume, let row?):
            withTask(row) { controller, workspaceID in controller.resumeAgentTask(workspaceID: workspaceID) }
        case (.review, let row?):
            withTask(row) { controller, workspaceID in _ = controller.openReview(workspaceID: workspaceID) }
        case (.merge, let row?):
            withTask(row) { controller, workspaceID in controller.mergeAgentTask(workspaceID: workspaceID) }
        case (.discard, let row?): ui.open(.discard(row.id))
        case (.allow, let row?): respond(.approve, to: row)
        case (.deny, let row?): respond(.deny, to: row)
        default: break
        }
    }

    /// Approve or deny a permission prompt, the way the remote page does: only
    /// the prompt the row showed (`updated_at`), never a question.
    private static func respond(_ response: AgentInbox.Response, to row: AgentCrewRow) {
        guard !row.asksQuestion else { return }
        let result = AgentInbox.shared.respond(
            ["tab_id": row.id.uuidString, "response": response.rawValue, "updated_at": row.updatedAt],
            deniedFrom: "the sidebar")
        if result["ok"] as? Bool != true {
            booLog(.info, .sidebar, "crew \(response.rawValue) failed: \(result["error"] ?? "")")
            NSSound.beep()
        }
    }

    static func withTask(_ row: AgentCrewRow, _ body: (MainWindowController, UUID) -> Void) {
        guard let location = AgentInbox.locateInWindows(row.id) else { return }
        body(location.controller, location.workspace.id)
    }

    /// Starts an agent on its own worktree of the active workspace's repository.
    static func startTask(
        prompt: String, agent: AgentKind = .claudeCode, completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let controller = WindowManager.shared.activeController else {
            completion("No Boo window to start the agent in.")
            return
        }
        controller.ipcNewAgentTask(json: ["prompt": prompt, "agent": agent.ipcName]) { reply in
            let error = reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "Unknown error"
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }
}
