import SwiftUI

/// Sidebar detail view for the OpenCode plugin.
/// Shows sessions, config files, skills, MCP servers, and changed files.
struct OpenCodeDetailView: View {
    let sessions: [OpenCodePlugin.OpenCodeSession]
    let diffStats: [OpenCodePlugin.DiffStatEntry]
    let agentConfig: OpenCodePlugin.AgentConfig
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onSessionClicked: (OpenCodePlugin.OpenCodeSession) -> Void
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onPasteSkill: (String) -> Void

    @State private var hoveredItemID: UUID?
    @State private var hoveredSessionID: String?
    @State private var sessionsExpanded = true
    @State private var configExpanded = true
    @State private var skillsExpanded = false
    @State private var changesExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionsSection
                configSection
                mcpSection
                skillsSection
                changedFilesSection
            }
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if !sessions.isEmpty {
            collapsibleHeader(
                "Sessions", icon: "bubble.left.and.bubble.right", count: sessions.count,
                isExpanded: $sessionsExpanded)

            if sessionsExpanded {
                ForEach(sessions.prefix(10)) { session in
                    sessionRow(session: session)
                }
            }

            Divider().opacity(0.3)
        }
    }

    private func sessionRow(session: OpenCodePlugin.OpenCodeSession) -> some View {
        let isHovered = hoveredSessionID == session.id

        return Button(action: { onSessionClicked(session) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let slug = session.slug {
                        Text(slug)
                            .font(fontScale.font(.base).weight(.medium))
                            .foregroundColor(accentColor)
                            .lineLimit(1)
                    } else {
                        Text(String(session.id.prefix(12)))
                            .font(fontScale.font(.base, design: .monospaced))
                            .foregroundColor(accentColor)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(formatRelativeDate(session.timestamp))
                        .font(fontScale.font(.xs))
                        .foregroundColor(mutedColor)
                }

                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .font(fontScale.font(.sm))
                        .foregroundColor(mutedColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
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
        .background(isHovered ? mutedColor.opacity(0.08) : Color.clear)
        .contextMenu {
            Button("Resume Session") { onSessionClicked(session) }
            Divider()
            Button("Copy Session ID") { onCopyPath(session.id) }
        }
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

    private func configRow(file: OpenCodePlugin.AgentConfig.ConfigFile) -> some View {
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
            Divider()
            Button("Copy Path") { onCopyPath(file.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            }
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
                        .font(fontScale.font(.base, design: .monospaced))
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

    private func skillRow(skill: OpenCodePlugin.AgentConfig.SkillEntry) -> some View {
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

    private func fileRow(entry: OpenCodePlugin.DiffStatEntry) -> some View {
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
                    .font(fontScale.font(.sm).weight(.semibold))
                    .foregroundColor(textColor)

                Spacer()

                if let trailing = trailing {
                    Text(trailing)
                        .font(fontScale.font(.xs, design: .monospaced))
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
                .font(fontScale.font(.sm).weight(.semibold))
                .foregroundColor(textColor)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Date Formatting

private func formatRelativeDate(_ date: Date) -> String {
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        let mins = Int(interval / 60)
        return "\(mins)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours)h ago"
    } else if interval < 604_800 {
        let days = Int(interval / 86400)
        return "\(days)d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
