import AppKit
import SwiftUI

/// The Crew section: every agent in every window with its handle, grouped by
/// what it needs from the user, plus the actions that used to hide in menus.
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
        taskStatus: (AgentInbox.Item) -> AgentTaskStatus.Summary? = { item in
            AgentInbox.locateInWindows(item.tabID).flatMap { location in
                let folder = location.workspace.folderPath
                guard AgentWorktree.looksLikeWorktree(folder) else { return nil }
                // A new state (a finished turn, a commit) asks git again.
                return AgentTaskStatus.shared.summary(for: folder, stamp: "\(item.state.rawValue)|\(item.updatedAt)")
            }
        }
    ) -> [AgentCrewRow] {
        items.map { item in
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
                updatedAt: item.updatedAt.timeIntervalSince1970, taskStatus: taskStatus(item))
        }.sorted { lhs, rhs in
            // Parents first, each helper right below the agent that started it.
            func order(_ row: AgentCrewRow) -> (Int, Int) {
                let own = Int(row.handle.dropFirst()) ?? 0
                return (row.parent.flatMap { Int($0.dropFirst()) } ?? own, row.parent == nil ? 0 : own)
            }
            return order(lhs) < order(rhs)
        }
    }

    /// Task workspaces under `~/.boo/worktrees` with no live agent in any tab,
    /// as stopped rows: after a restart the workspaces come back but the agents
    /// don't, and the work still needs a Review, Merge or Discard.
    static func stoppedTaskRows(
        workspaces: [Workspace], live: Set<UUID>,
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
                isStopped: true, taskStatus: taskStatus(workspace.folderPath))
        }
    }

    /// Live agents, then stopped task workspaces, across every window.
    static func allCrewRows() -> [AgentCrewRow] {
        let items = Array(AgentInbox.shared.items.values)
        return crewRows(items: items, crew: AgentCrew.shared)
            + stoppedTaskRows(
                workspaces: WindowManager.shared.controllers.flatMap(\.appState.workspaces),
                live: Set(items.map(\.tabID)))
    }

    func makeCrewSection(
        fontScale: SidebarFontScale, textColor: Color, mutedColor: Color, accentColor: Color
    ) -> SidebarSection? {
        startCrewObserving()
        // Shown with no agents too: it is where one is started. Without an
        // agent CLI the tab's own empty state says what to install.
        let rows = Self.allCrewRows()
        let agents = AgentKind.taskKinds.filter { installedAgents.contains($0) }
        guard !rows.isEmpty || !agents.isEmpty else { return nil }
        // Counts the "Needs you" group only: an unread answer is bold under Done, not waiting.
        let waiting = rows.filter { !$0.isStopped && ($0.state == .needsInput || $0.state == .error) }.count
        return SidebarSection(
            id: "agents.crew",
            name: waiting > 0 ? "Agents (\(waiting) need you)" : rows.isEmpty ? "Agents" : "Agents (\(rows.count))",
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
                    onStartTask: { prompt, agent, completion in
                        Self.startTask(prompt: prompt, agent: agent, completion: completion)
                    },
                    agents: agents,
                    onStartHere: { [weak self] kind in self?.startAgent(kind: kind) },
                    onRespond: { row, response in Self.perform(response == .approve ? .allow : .deny, on: row) },
                    onResume: { Self.perform(.resume, on: $0) })),
            // Sized to its rows, so every agent shows without scrolling.
            prefersOuterScrollView: false,
            generation: SidebarSection.generation(for: rows.map(\.key) + installedAgents.map(\.rawValue).sorted()))
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
            AgentInbox.shared.jump(to: row.id)
        case (.message, let row?):
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
