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

        // No agent CLI installed: the crew section is gone too, so say what to install.
        if sections.isEmpty && Self.installedAgents.isEmpty {
            let emptyContent = AnyView(
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
            let emptySection = SidebarSection(
                id: "agents.empty",
                name: "Agents",
                icon: "sparkles",
                content: emptyContent,
                prefersOuterScrollView: false,
                generation: SidebarSection.generation(
                    for: Self.installedAgents.map(\.rawValue).sorted()))
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
