import AppKit
import SwiftUI

private func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
        return String(format: "%.1fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
}

// MARK: - Agent Center Views

struct AgentOpenSessionsView: View {
    let sessions: [WorkspaceAgentSession]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onSessionClicked: (WorkspaceAgentSession) -> Void
    let onResume: (WorkspaceAgentSession) -> Void
    let onCopySessionID: (WorkspaceAgentSession) -> Void
    let onOpenTranscript: (WorkspaceAgentSession) -> Void

    @State private var hoveredSessionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: WorkspaceAgentSession) -> some View {
        let isHovered = hoveredSessionID == session.id
        return Button(action: { onSessionClicked(session) }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isFocused ? Color.green : accentColor.opacity(0.65))
                    .frame(width: 7, height: 7)
                Text(session.agent.kind.shortName)
                    .font(fontScale.font(.base).weight(.semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Text(session.agent.cwd)
                    .font(fontScale.font(.xs))
                    .foregroundStyle(mutedColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isHovered ? accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            hoveredSessionID = hovered ? session.id : nil
        }
        .contextMenu {
            Button("Focus") { onSessionClicked(session) }
            Button("Resume") { onResume(session) }
            Divider()
            Button("Copy Session ID") { onCopySessionID(session) }
                .disabled(session.agent.sessionID == nil)
            Button("Open Transcript") { onOpenTranscript(session) }
                .disabled(session.agent.transcriptPath == nil)
        }
    }
}

// MARK: - Config Section View

struct ClaudeConfigView: View {
    let configFiles: [AgentsPlugin.AgentConfig.ConfigFile]
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

    private func configRow(file: AgentsPlugin.AgentConfig.ConfigFile) -> some View {
        let isHovered = hoveredItemID == file.id

        return Button(action: { onFileClicked(file.path) }) {
            HStack(spacing: 6) {
                Image(systemName: file.icon)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(file.scope == "global" ? mutedColor : accentColor)
                    .frame(width: 14)

                Text(file.name)
                    .font(fontScale.font(.base))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                Spacer()

                if file.provider != .claudeCode {
                    Text(file.provider.shortName)
                        .font(fontScale.font(.xs).weight(.medium))
                        .foregroundStyle(accentColor.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(accentColor.opacity(0.08))
                        )
                }

                if file.scope == "global" {
                    Text("global")
                        .font(fontScale.font(.xs).weight(.medium))
                        .foregroundStyle(mutedColor.opacity(0.7))
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

// MARK: - Agent Center Settings View

struct AgentCenterSettingsView: View {
    var installedAgents: Set<AgentKind> = Set(AgentKind.allCases).subtracting([.custom])

    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])
    @State private var refreshID = UUID()

    var body: some View {
        let _ = observer.revision
        let _ = refreshID
        let t = Tokens.current

        VStack(alignment: .leading, spacing: 12) {
            Section(title: "Providers", spacing: 8, padding: 10) {
                let providers = [AgentKind.claudeCode, .codex, .openCode]
                    .filter { installedAgents.contains($0) }
                if providers.isEmpty {
                    Text("No agent CLIs found. Install claude, codex, or opencode.")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                } else {
                    ForEach(providers, id: \.self) { kind in
                        mergedProviderRow(kind: kind, t: t)
                    }
                }
            }
        }
    }

    private func mergedProviderRow(kind: AgentKind, t: Tokens) -> some View {
        let files = AgentsPlugin.detectAgentConfig(cwd: NSHomeDirectory()).configFiles.filter {
            $0.provider == kind
        }
        let binaryName = kind.processNames.first ?? ""
        let binaryPath = BinaryScanner.searchPaths
            .map { ($0 as NSString).appendingPathComponent(binaryName) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let isFound = binaryPath != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isFound ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text)
                Spacer()
                Text(isFound ? "Installed" : "Not found")
                    .font(.system(size: 10))
                    .foregroundStyle(isFound ? Color.green : t.muted)
            }

            if let path = binaryPath {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(t.muted)
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(t.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(t.muted)
                                .frame(width: 12)
                            Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 10))
                                .foregroundStyle(t.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Open") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            } else {
                Text("No config file found.")
                    .font(.system(size: 10))
                    .foregroundStyle(t.muted)
            }
        }
        .padding(10)
        .background(t.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

}

// MARK: - Skills Section View

struct ClaudeSkillsView: View {
    let skills: [AgentsPlugin.AgentConfig.SkillEntry]
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

    private func skillRow(skill: AgentsPlugin.AgentConfig.SkillEntry) -> some View {
        let isHovered = hoveredItemID == skill.id

        return Button(action: { onPasteSkill(skill.name) }) {
            HStack(spacing: 6) {
                Text("/\(skill.name)")
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(fontScale.font(.sm))
                        .foregroundStyle(mutedColor)
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
    let diffStats: [AgentsPlugin.DiffStatEntry]
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

    private func fileRow(entry: AgentsPlugin.DiffStatEntry) -> some View {
        Button(action: { onFileClicked(entry.fullPath) }) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text("+\(entry.insertions)")
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("-\(entry.deletions)")
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                .frame(width: 56, alignment: .leading)

                Text(entry.path)
                    .font(fontScale.font(.base))
                    .foregroundStyle(textColor)
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

// MARK: - Settings Section View

struct ClaudeSettingsView: View {
    let settings: AgentsPlugin.ClaudeSettings
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
                        .foregroundStyle(accentColor)
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
                            .foregroundStyle(mutedColor)
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
                .foregroundStyle(accentColor)
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
                .foregroundStyle(mutedColor)
                .frame(width: 16)

            Text(label)
                .font(fontScale.font(.base))
                .foregroundStyle(textColor)

            Spacer()

            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Worktrees Section View

struct ClaudeWorktreesView: View {
    let worktrees: [AgentsPlugin.ClaudeWorktree]
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onWorktreeClicked: (AgentsPlugin.ClaudeWorktree) -> Void
    let onCopyPath: (String) -> Void

    @State private var hoveredWorktreeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(worktrees) { worktree in
                worktreeRow(worktree: worktree)
            }
        }
    }

    private func worktreeRow(worktree: AgentsPlugin.ClaudeWorktree) -> some View {
        let isHovered = hoveredWorktreeID == worktree.id

        return Button(action: { onWorktreeClicked(worktree) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(fontScale.font(.sm))
                        .foregroundStyle(accentColor)

                    Text(worktree.id)
                        .font(fontScale.font(.base).weight(.medium))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)

                    Spacer()

                    if let created = worktree.created {
                        Text(formatAgentRelativeDate(created))
                            .font(fontScale.font(.xs))
                            .foregroundStyle(mutedColor)
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
                    .foregroundStyle(mutedColor.opacity(0.8))

                    if let head = worktree.headCommit {
                        HStack(spacing: 2) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                            Text(head)
                        }
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundStyle(mutedColor.opacity(0.7))
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
