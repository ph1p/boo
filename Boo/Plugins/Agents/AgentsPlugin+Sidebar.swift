import AppKit
import SwiftUI

extension AgentsPlugin {
    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let start = agentStartTime else { return nil }
        var text = activeAgent?.kind.shortName ?? "Agent"
        if !diffStats.isEmpty {
            let count = diffStats.count
            text += " \u{00B7} \(count) file\(count == 1 ? "" : "s")"
        }
        let mins = Int(Date().timeIntervalSince(start) / 60)
        if mins > 0 {
            text += " \u{00B7} \(formatAgentRuntime(Date().timeIntervalSince(start)))"
        }
        return StatusBarContent(
            text: text,
            icon: "sparkles",
            tint: .accent,
            accessibilityLabel: "Agent Center: \(text)"
        )
    }

    // MARK: - Section Title

    func sectionTitle(context: PluginContext) -> String? {
        guard let start = agentStartTime else { return nil }
        let runtime = Date().timeIntervalSince(start)
        return "\(activeAgent?.kind.shortName ?? "Agent") \u{00B7} \(formatAgentRuntime(runtime))"
    }

    // MARK: - Sidebar Tab (multi-section)

    func makeSidebarTab(context: PluginContext) -> SidebarTab? {
        guard manifest.capabilities?.sidebarTab == true else { return nil }

        // If no agent running, scan config/sessions/worktrees based on current terminal CWD
        let isAgentActive = agentStartTime != nil
        if !isAgentActive && currentCwd != context.terminal.cwd {
            scanAgentConfig(cwd: context.terminal.cwd)
            scanWorktrees(cwd: context.terminal.cwd)
        }

        let act = actions
        let fontScale = context.fontScale
        let textColor = Color(nsColor: context.theme.chromeText)
        let mutedColor = Color(nsColor: context.theme.chromeMuted)
        let accentColor = Color(nsColor: context.theme.accentColor)

        var sections: [SidebarSection] = []

        if let crew = makeCrewSection(
            fontScale: fontScale, textColor: textColor, mutedColor: mutedColor, accentColor: accentColor)
        {
            sections.append(crew)
        }

        let openSessions = actions?.workspaceAgentSessions?() ?? []
        if !openSessions.isEmpty {
            let openSessionsSection = SidebarSection(
                id: "agents.open.sessions",
                name: "Open Sessions (\(openSessions.count))",
                icon: "rectangle.3.group",
                content: AnyView(
                    AgentOpenSessionsView(
                        sessions: openSessions,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onSessionClicked: { session in
                            act?.focusAgentSession?(session.id)
                        },
                        onResume: { [weak self] session in
                            self?.startAgent(
                                kind: session.agent.kind,
                                cwd: session.agent.cwd,
                                resumeSessionID: session.agent.sessionID)
                        },
                        onCopySessionID: { session in
                            guard let id = session.agent.sessionID else { return }
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: id))
                        },
                        onOpenTranscript: { session in
                            guard let path = session.agent.transcriptPath else { return }
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onShowTimeline: { session in
                            guard let id = session.agent.sessionID else { return }
                            let folder = (session.agent.cwd as NSString).lastPathComponent
                            act?.openAgentTimeline?(id, "\(session.agent.kind.shortName) — \(folder)")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(
                    for: openSessions.map {
                        "\($0.id)|\($0.tabTitle)|\($0.isFocused)|\($0.agent.state.rawValue)"
                    }))
            sections.append(openSessionsSection)
        }

        // Changes section — the diff-stat poll already runs while an agent is active
        // and feeds the status bar's file count; surface the per-file rows too.
        if !diffStats.isEmpty {
            let changesSection = SidebarSection(
                id: "agents.changes",
                name: "Changes (\(diffStats.count))",
                icon: "plusminus",
                content: AnyView(
                    ClaudeChangesView(
                        diffStats: diffStats,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onReferenceInAI: { path in
                            act?.sendToTerminal?("@\(path) ")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(
                    for:
                        diffStats.map { "\($0.path)|\($0.insertions)|\($0.deletions)" }))
            sections.append(changesSection)
        }

        // Worktrees section
        if !worktrees.isEmpty {
            let worktreesSection = SidebarSection(
                id: "agents.claude.worktrees",
                name: "Worktrees (\(worktrees.count))",
                icon: "arrow.triangle.branch",
                content: AnyView(
                    ClaudeWorktreesView(
                        worktrees: worktrees,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onWorktreeClicked: { [weak self] worktree in
                            self?.openWorktree(worktree)
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        }
                    )),
                prefersOuterScrollView: true,
                // Count alone is not enough: switching to a project with the same
                // number of worktrees left the previous project's rows on screen.
                generation: SidebarSection.generation(
                    for: worktrees.map { "\($0.path)|\($0.branch)|\($0.headCommit ?? "")" }))
            sections.append(worktreesSection)
        }

        // Config section
        if !agentConfig.configFiles.isEmpty {
            let configSection = SidebarSection(
                id: "agents.config",
                name: "Config (\(agentConfig.configFiles.count))",
                icon: "doc.text",
                content: AnyView(
                    ClaudeConfigView(
                        configFiles: agentConfig.configFiles,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onReferenceInAI: { path in
                            act?.sendToTerminal?("@\(path) ")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(for: agentConfig.configFiles.map { "\($0.path)|\($0.scope)" }))
            sections.append(configSection)
        }

        // Skills section
        if !agentConfig.skills.isEmpty {
            let skillsSection = SidebarSection(
                id: "agents.skills",
                name: "Skills (\(agentConfig.skills.count))",
                icon: "star",
                content: AnyView(
                    ClaudeSkillsView(
                        skills: agentConfig.skills,
                        fontScale: fontScale,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        accentColor: accentColor,
                        onFileClicked: { path in
                            act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                        },
                        onCopyPath: { path in
                            act?.handle(DSLAction(type: "copy", path: nil, command: nil, text: path))
                        },
                        onPasteSkill: { name in
                            act?.sendToTerminal?("/\(name)")
                        }
                    )),
                prefersOuterScrollView: true,
                generation: SidebarSection.generation(for: agentConfig.skills.map { "\($0.path)|\($0.name)" }))
            sections.append(skillsSection)
        }

        // If no sections (no agent, no sessions, no config), show getting started
        if sections.isEmpty {
            let available = [AgentKind.claudeCode, .codex, .openCode]
                .filter { installedAgents.contains($0) }
            let emptyContent: AnyView
            if available.isEmpty {
                emptyContent = AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No agent CLIs installed")
                            .font(fontScale.font(.base))
                            .foregroundStyle(textColor)
                        Text("Install claude, codex, or opencode to get started.")
                            .font(fontScale.font(.sm))
                            .foregroundStyle(mutedColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                )
            } else {
                emptyContent = AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No active agent in this tab")
                            .font(fontScale.font(.base))
                            .foregroundStyle(textColor)
                        Text("Start an agent here to see workspace sessions.")
                            .font(fontScale.font(.sm))
                            .foregroundStyle(mutedColor)
                        HStack(spacing: 8) {
                            ForEach(available, id: \.self) { kind in
                                Button("Start \(kind.shortName)") { self.startAgent(kind: kind) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                )
            }
            let emptySection = SidebarSection(
                id: "agents.empty",
                name: "Agents",
                icon: "sparkles",
                content: emptyContent,
                prefersOuterScrollView: false,
                generation: SidebarSection.generation(
                    for: installedAgents.map(\.rawValue).sorted()))
            sections.append(emptySection)
        }

        return SidebarTab(
            id: SidebarTabID(manifest.id),
            icon: manifest.icon,
            label: manifest.name,
            sections: sections)
    }

    func makeDetailView(context: PluginContext) -> AnyView? { nil }

}
