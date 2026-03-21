import SwiftUI

/// Sidebar detail view for the AI Agent Monitor plugin.
/// Shows agent info, config files, hooks, skills, MCP servers, and changed files.
struct AIAgentDetailView: View {
    let agentName: String
    let agentIcon: String
    let runtime: TimeInterval
    let cwd: String
    let diffStats: [AIAgentPlugin.DiffStatEntry]
    let agentConfig: AIAgentPlugin.AgentConfig
    let fontSize: CGFloat
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onReferenceInAI: (String) -> Void
    let onPasteSkill: (String) -> Void
    let onRefresh: () -> Void

    @State private var hoveredItemID: UUID?
    @State private var skillsExpanded = false
    @State private var configExpanded = true
    @State private var changesExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                agentHeader
                cwdRow
                Divider().opacity(0.3)
                configSection
                hooksSection
                mcpSection
                skillsSection
                changedFilesSection
            }
        }
    }

    // MARK: - Agent Header

    private var agentHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: agentIcon)
                .font(.system(size: 12))
                .foregroundColor(accentColor)
            Text(agentName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accentColor)
            Spacer()
            Text(formatRuntime(runtime))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(mutedColor)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(mutedColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI Agent: \(agentName), running for \(formatRuntime(runtime))")
    }

    // MARK: - CWD Row

    private var cwdRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: fontSize - 1))
                .foregroundColor(mutedColor)
            Text(abbreviatePath(cwd))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Config Files

    @ViewBuilder
    private var configSection: some View {
        if !agentConfig.configFiles.isEmpty {
            collapsibleHeader(
                "Config", icon: "doc.text", count: agentConfig.configFiles.count, isExpanded: $configExpanded)

            if configExpanded {
                ForEach(agentConfig.configFiles) { file in
                    configRow(file: file)
                }
            }

            Divider().opacity(0.3)
        }
    }

    private func configRow(file: AIAgentPlugin.AgentConfig.ConfigFile) -> some View {
        let isHovered = hoveredItemID == file.id

        return Button(action: { onFileClicked(file.path) }) {
            HStack(spacing: 6) {
                Image(systemName: file.icon)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(file.scope == "global" ? mutedColor : accentColor)
                    .frame(width: 14)

                Text(file.name)
                    .font(.system(size: 11))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Spacer()

                if file.scope == "global" {
                    Text("global")
                        .font(.system(size: 8, weight: .medium))
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

    // MARK: - Hooks

    @ViewBuilder
    private var hooksSection: some View {
        if !agentConfig.hooks.isEmpty {
            staticHeader("Hooks", icon: "arrow.triangle.turn.up.right.diamond", count: agentConfig.hooks.count)

            ForEach(agentConfig.hooks) { hook in
                HStack(spacing: 6) {
                    Text(hook.event)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(accentColor)
                        .lineLimit(1)

                    Spacer()

                    Text(hook.command)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 4)
                .padding(.vertical, 2)
            }

            Divider().opacity(0.3)
        }
    }

    // MARK: - MCP Servers

    @ViewBuilder
    private var mcpSection: some View {
        if !agentConfig.mcpServers.isEmpty {
            staticHeader("MCP Servers", icon: "server.rack", count: agentConfig.mcpServers.count)

            ForEach(agentConfig.mcpServers, id: \.self) { server in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 4, height: 4)

                    Text(server)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.leading, 4)
                .padding(.vertical, 2)
            }

            Divider().opacity(0.3)
        }
    }

    // MARK: - Skills

    @ViewBuilder
    private var skillsSection: some View {
        if !agentConfig.skills.isEmpty {
            collapsibleHeader("Skills", icon: "star", count: agentConfig.skills.count, isExpanded: $skillsExpanded)

            if skillsExpanded {
                ForEach(agentConfig.skills) { skill in
                    skillRow(skill: skill)
                }
            }

            Divider().opacity(0.3)
        }
    }

    private func skillRow(skill: AIAgentPlugin.AgentConfig.SkillEntry) -> some View {
        let isHovered = hoveredItemID == skill.id

        return Button(action: { onPasteSkill(skill.name) }) {
            HStack(spacing: 6) {
                Text("/\(skill.name)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 10))
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

    // MARK: - Changed Files

    @ViewBuilder
    private var changedFilesSection: some View {
        if !diffStats.isEmpty {
            collapsibleHeader(
                "Changes", icon: "doc.badge.plus", count: diffStats.count, isExpanded: $changesExpanded,
                trailing: totalStats)

            if changesExpanded {
                ForEach(diffStats) { entry in
                    fileRow(entry: entry)
                }
            }
        }
    }

    private var totalStats: String {
        let ins = diffStats.reduce(0) { $0 + $1.insertions }
        let del = diffStats.reduce(0) { $0 + $1.deletions }
        return "+\(ins) -\(del)"
    }

    private func fileRow(entry: AIAgentPlugin.DiffStatEntry) -> some View {
        Button(action: { onFileClicked(entry.fullPath) }) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text("+\(entry.insertions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    Text("-\(entry.deletions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemRed))
                }
                .frame(width: 56, alignment: .leading)

                Text(entry.path)
                    .font(.system(size: 11))
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

    // MARK: - Section Headers

    private func collapsibleHeader(
        _ title: String, icon: String, count: Int,
        isExpanded: Binding<Bool>, trailing: String? = nil
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(mutedColor)
                    .frame(width: 8)

                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(mutedColor)

                Text("\(title) (\(count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(textColor)

                Spacer()

                if let trailing = trailing {
                    Text(trailing)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(mutedColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func staticHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(mutedColor)

            Text("\(title) (\(count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(textColor)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Helpers

private func formatRuntime(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let mins = (totalSeconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(mins)m"
    } else if mins > 0 {
        return "\(mins)m"
    } else {
        return "<1m"
    }
}

// abbreviatePath() is provided by ExtermPaths.swift as a global function
