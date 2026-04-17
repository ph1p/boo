import SwiftUI

private func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
        return String(format: "%.1fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
}

// MARK: - Sessions Section View

struct ClaudeSessionsView: View {
    let sessions: [ClaudeCodePlugin.ClaudeSession]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onSessionClicked: (ClaudeCodePlugin.ClaudeSession) -> Void
    let onCopyPath: (String) -> Void

    @State private var hoveredSessionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                sessionRow(session: session)
            }
        }
    }

    private func sessionRow(session: ClaudeCodePlugin.ClaudeSession) -> some View {
        let isHovered = hoveredSessionID == session.id

        return Button(action: { onSessionClicked(session) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Active indicator
                    if session.isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }

                    if let slug = session.slug {
                        Text(slug)
                            .font(fontScale.font(.base).weight(.medium))
                            .foregroundColor(session.isActive ? .green : accentColor)
                            .lineLimit(1)
                    } else {
                        Text(String(session.id.prefix(8)))
                            .font(fontScale.font(.base, design: .monospaced))
                            .foregroundColor(session.isActive ? .green : accentColor)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Relative time
                    Text(formatAgentRelativeDate(session.lastActivity ?? session.timestamp))
                        .font(fontScale.font(.xs))
                        .foregroundColor(mutedColor)
                }

                if !session.firstMessage.isEmpty {
                    Text(session.firstMessage)
                        .font(fontScale.font(.sm))
                        .foregroundColor(mutedColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                // Stats row
                HStack(spacing: 8) {
                    if session.messageCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9))
                            Text("\(session.messageCount)")
                        }
                        .font(fontScale.font(.xs))
                        .foregroundColor(mutedColor.opacity(0.7))
                    }

                    if session.totalTokens > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                            Text(formatTokenCount(session.totalTokens))
                        }
                        .font(fontScale.font(.xs))
                        .foregroundColor(mutedColor.opacity(0.7))
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSessionID = hovering ? session.id : nil
        }
        .background(
            Group {
                if session.isActive {
                    Color.green.opacity(0.08)
                } else if isHovered {
                    mutedColor.opacity(0.08)
                } else {
                    Color.clear
                }
            }
        )
        .contextMenu {
            Button("Resume in New Tab") { onSessionClicked(session) }
            Divider()
            Button("Copy Session ID") { onCopyPath(session.id) }
            Button("Reveal Session File") {
                NSWorkspace.shared.selectFile(session.path, inFileViewerRootedAtPath: "")
            }
        }
    }

}

// MARK: - Config Section View

struct ClaudeConfigView: View {
    let configFiles: [ClaudeCodePlugin.AgentConfig.ConfigFile]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onReferenceInAI: (String) -> Void

    @State private var hoveredItemID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(configFiles) { file in
                configRow(file: file)
            }
        }
    }

    private func configRow(file: ClaudeCodePlugin.AgentConfig.ConfigFile) -> some View {
        let isHovered = hoveredItemID == file.id

        return Button(action: { onFileClicked(file.path) }) {
            HStack(spacing: 6) {
                Image(systemName: file.icon)
                    .font(fontScale.font(.sm))
                    .foregroundColor(file.scope == "global" ? mutedColor : accentColor)
                    .frame(width: 14)

                Text(file.name)
                    .font(fontScale.font(.base))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Spacer()

                if file.scope == "global" {
                    Text("global")
                        .font(fontScale.font(.xs).weight(.medium))
                        .foregroundColor(mutedColor.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(mutedColor.opacity(0.1))
                        )
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItemID = hovering ? file.id : nil
        }
        .background(isHovered ? mutedColor.opacity(0.08) : Color.clear)
        .contextMenu {
            Button("Open in Editor") { onFileClicked(file.path) }
            Button("Reference in AI (@)") { onReferenceInAI(file.path) }
            Divider()
            Button("Copy Path") { onCopyPath(file.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

// MARK: - Hooks Section View

struct ClaudeHooksView: View {
    let hooks: [ClaudeCodePlugin.AgentConfig.HookEntry]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hooks) { hook in
                HStack(spacing: 6) {
                    Text(hook.event)
                        .font(fontScale.font(.sm, design: .monospaced).weight(.medium))
                        .foregroundColor(accentColor)
                        .lineLimit(1)

                    Spacer()

                    Text(hook.command)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 4)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - MCP Servers Section View

struct ClaudeMCPView: View {
    let mcpServers: [String]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(mcpServers, id: \.self) { server in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 4, height: 4)

                    Text(server)
                        .font(fontScale.font(.base, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.leading, 4)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Skills Section View

struct ClaudeSkillsView: View {
    let skills: [ClaudeCodePlugin.AgentConfig.SkillEntry]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onPasteSkill: (String) -> Void

    @State private var hoveredItemID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(skills) { skill in
                skillRow(skill: skill)
            }
        }
    }

    private func skillRow(skill: ClaudeCodePlugin.AgentConfig.SkillEntry) -> some View {
        let isHovered = hoveredItemID == skill.id

        return Button(action: { onPasteSkill(skill.name) }) {
            HStack(spacing: 6) {
                Text("/\(skill.name)")
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(fontScale.font(.sm))
                        .foregroundColor(mutedColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItemID = hovering ? skill.id : nil
        }
        .background(isHovered ? mutedColor.opacity(0.08) : Color.clear)
        .contextMenu {
            Button("Open Skill") { onFileClicked(skill.path) }
            Divider()
            Button("Copy Path") { onCopyPath(skill.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(skill.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

// MARK: - Changes Section View

struct ClaudeChangesView: View {
    let diffStats: [ClaudeCodePlugin.DiffStatEntry]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onReferenceInAI: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffStats) { entry in
                fileRow(entry: entry)
            }
        }
    }

    private func fileRow(entry: ClaudeCodePlugin.DiffStatEntry) -> some View {
        Button(action: { onFileClicked(entry.fullPath) }) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text("+\(entry.insertions)")
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    Text("-\(entry.deletions)")
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemRed))
                }
                .frame(width: 56, alignment: .leading)

                Text(entry.path)
                    .font(fontScale.font(.base))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reference in AI (@)") { onReferenceInAI(entry.path) }
            Button("Open in Editor") { onFileClicked(entry.fullPath) }
            Divider()
            Button("Copy Path") { onCopyPath(entry.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(entry.fullPath, inFileViewerRootedAtPath: "")
            }
        }
        .accessibilityLabel("\(entry.path): \(entry.insertions) insertions, \(entry.deletions) deletions")
    }
}

// MARK: - Active Session View

struct ClaudeActiveSessionView: View {
    let agentStartTime: Date?
    let activeSession: ClaudeCodePlugin.ClaudeSession?
    let activeSessionID: String?
    let diffStats: [ClaudeCodePlugin.DiffStatEntry]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status row
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text("Claude Code")
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundColor(textColor)

                Spacer()

                if let start = agentStartTime {
                    Text(formatAgentRuntime(Date().timeIntervalSince(start)))
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(mutedColor)
                }
            }

            // Session info
            if let session = activeSession {
                VStack(alignment: .leading, spacing: 4) {
                    // Session name/slug
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10))
                            .foregroundColor(mutedColor)

                        if let slug = session.slug {
                            Text(slug)
                                .font(fontScale.font(.sm).weight(.medium))
                                .foregroundColor(accentColor)
                        } else {
                            Text(String(session.id.prefix(8)))
                                .font(fontScale.font(.sm, design: .monospaced))
                                .foregroundColor(accentColor)
                        }
                    }

                    // First message preview
                    if !session.firstMessage.isEmpty {
                        Text(session.firstMessage)
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor)
                            .lineLimit(2)
                    }

                    // Stats
                    HStack(spacing: 12) {
                        if session.messageCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 9))
                                Text("\(session.messageCount)")
                            }
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor.opacity(0.8))
                        }

                        if session.totalTokens > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "number")
                                    .font(.system(size: 9))
                                Text(formatTokenCount(session.totalTokens))
                            }
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor.opacity(0.8))
                        }

                        if !diffStats.isEmpty {
                            let ins = diffStats.reduce(0) { $0 + $1.insertions }
                            let del = diffStats.reduce(0) { $0 + $1.deletions }
                            HStack(spacing: 3) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 9))
                                Text("\(diffStats.count)")
                                Text("+\(ins)")
                                    .foregroundColor(Color(nsColor: .systemGreen))
                                Text("-\(del)")
                                    .foregroundColor(Color(nsColor: .systemRed))
                            }
                            .font(fontScale.font(.xs, design: .monospaced))
                            .foregroundColor(mutedColor.opacity(0.8))
                        }
                    }
                }
                .padding(.leading, 16)
            } else if let sessionID = activeSessionID {
                // Session ID known but details not loaded
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                        .foregroundColor(mutedColor)
                    Text(String(sessionID.prefix(8)))
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(mutedColor)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

}

// MARK: - Settings Section View

struct ClaudeSettingsView: View {
    let settings: ClaudeCodePlugin.ClaudeSettings
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onSettingChanged: (String, Any) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Model display
            settingRow(
                icon: "cpu",
                label: "Model",
                content: AnyView(
                    Text(settings.modelDisplayName)
                        .font(fontScale.font(.sm, design: .monospaced))
                        .foregroundColor(accentColor)
                )
            )

            // Effort level picker
            settingRow(
                icon: "gauge.with.dots.needle.50percent",
                label: "Effort",
                content: AnyView(
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.effortLevel },
                            set: { onSettingChanged("effortLevel", $0) }
                        )
                    ) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                )
            )

            // Extended thinking toggle
            settingRow(
                icon: "brain",
                label: "Extended Thinking",
                content: AnyView(
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.alwaysThinkingEnabled },
                            set: { onSettingChanged("alwaysThinkingEnabled", $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                )
            )

            // Voice toggle
            settingRow(
                icon: "waveform",
                label: "Voice",
                content: AnyView(
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.voiceEnabled },
                            set: { onSettingChanged("voiceEnabled", $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                )
            )

            // Enabled plugins count
            if !settings.enabledPlugins.isEmpty {
                settingRow(
                    icon: "puzzlepiece.extension",
                    label: "Plugins",
                    content: AnyView(
                        Text("\(settings.enabledPlugins.count) enabled")
                            .font(fontScale.font(.sm))
                            .foregroundColor(mutedColor)
                    )
                )
            }

            // Open settings button
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                    Text("Open settings.json")
                        .font(fontScale.font(.sm))
                }
                .foregroundColor(accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func settingRow(icon: String, label: String, content: AnyView) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(mutedColor)
                .frame(width: 16)

            Text(label)
                .font(fontScale.font(.base))
                .foregroundColor(textColor)

            Spacer()

            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Worktrees Section View

struct ClaudeWorktreesView: View {
    let worktrees: [ClaudeCodePlugin.ClaudeWorktree]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onWorktreeClicked: (ClaudeCodePlugin.ClaudeWorktree) -> Void
    let onCopyPath: (String) -> Void

    @State private var hoveredWorktreeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(worktrees) { worktree in
                worktreeRow(worktree: worktree)
            }
        }
    }

    private func worktreeRow(worktree: ClaudeCodePlugin.ClaudeWorktree) -> some View {
        let isHovered = hoveredWorktreeID == worktree.id

        return Button(action: { onWorktreeClicked(worktree) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(fontScale.font(.sm))
                        .foregroundColor(accentColor)

                    Text(worktree.id)
                        .font(fontScale.font(.base).weight(.medium))
                        .foregroundColor(accentColor)
                        .lineLimit(1)

                    Spacer()

                    if let created = worktree.created {
                        Text(formatAgentRelativeDate(created))
                            .font(fontScale.font(.xs))
                            .foregroundColor(mutedColor)
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 9))
                        Text(worktree.branch)
                            .lineLimit(1)
                    }
                    .font(fontScale.font(.xs, design: .monospaced))
                    .foregroundColor(mutedColor.opacity(0.8))

                    if let head = worktree.headCommit {
                        HStack(spacing: 2) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                            Text(head)
                        }
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundColor(mutedColor.opacity(0.7))
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredWorktreeID = hovering ? worktree.id : nil
        }
        .background(isHovered ? mutedColor.opacity(0.08) : Color.clear)
        .contextMenu {
            Button("Open in New Tab") { onWorktreeClicked(worktree) }
            Divider()
            Button("Copy Path") { onCopyPath(worktree.path) }
            Button("Copy Branch Name") { onCopyPath(worktree.branch) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(worktree.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}
