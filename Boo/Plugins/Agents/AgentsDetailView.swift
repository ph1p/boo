import AppKit
import SwiftUI

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
        let grouped = Dictionary(grouping: configFiles, by: \.provider)
        let providers = [AgentKind.claudeCode, .codex, .openCode]
            .filter { grouped[$0] != nil }
        let needsHeaders = providers.count > 1

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(providers, id: \.self) { provider in
                if needsHeaders {
                    Text(provider.displayName)
                        .font(fontScale.font(.xs).weight(.semibold))
                        .foregroundStyle(mutedColor)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                }
                ForEach(grouped[provider] ?? []) { file in
                    configRow(file: file)
                }
                if needsHeaders && provider != providers.last {
                    Divider()
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
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
            Section(title: "Providers") {
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
                    .fill(isFound ? t.success : t.warning)
                    .frame(width: 7, height: 7)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text)
                Spacer()
                Text(isFound ? "Installed" : "Not found")
                    .font(.system(size: 10))
                    .foregroundStyle(isFound ? t.success : t.muted)
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
                            .buttonStyle(.themed(.secondary))
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

                    // Full paths share a long prefix and truncate to the same text.
                    Text((worktree.path as NSString).lastPathComponent)
                        .font(fontScale.font(.base).weight(.medium))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                        .help(worktree.path)

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
