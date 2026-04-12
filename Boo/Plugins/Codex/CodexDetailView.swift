import SwiftUI

/// Sidebar detail view for the Codex plugin.
/// Shows sessions, config files, and changed files.
struct CodexDetailView: View {
    let sessions: [CodexPlugin.CodexSession]
    let diffStats: [CodexPlugin.DiffStatEntry]
    let agentConfig: CodexPlugin.AgentConfig
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let currentCwd: String?
    let onSessionClicked: (CodexPlugin.CodexSession) -> Void
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void

    @State private var hoveredItemID: UUID?
    @State private var hoveredSessionID: String?
    @State private var sessionsExpanded = true
    @State private var configExpanded = true
    @State private var changesExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionsSection
                configSection
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
                ForEach(sessions) { session in
                    sessionRow(session: session)
                }
            }

            Divider().opacity(0.3)
        }
    }

    private func sessionRow(session: CodexPlugin.CodexSession) -> some View {
        let isHovered = hoveredSessionID == session.id

        return Button(action: { onSessionClicked(session) }) {
            HStack(spacing: 6) {
                Text(String(session.id.prefix(8)))
                    .font(fontScale.font(.base, design: .monospaced))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                if let model = session.model {
                    Text(model)
                        .font(fontScale.font(.xs))
                        .foregroundColor(mutedColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(mutedColor.opacity(0.1))
                        )
                }

                Spacer()

                Text(formatRelativeDate(session.timestamp))
                    .font(fontScale.font(.xs))
                    .foregroundColor(mutedColor)
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

    private func configRow(file: CodexPlugin.AgentConfig.ConfigFile) -> some View {
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

    private func fileRow(entry: CodexPlugin.DiffStatEntry) -> some View {
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
