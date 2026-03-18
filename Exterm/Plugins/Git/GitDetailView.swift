import SwiftUI

// MARK: - Git Detail View

struct GitDetailView: View {
    let branch: String
    let aheadCount: Int
    let behindCount: Int
    let lastCommit: String?
    let stashCount: Int
    let changedFiles: [GitPlugin.GitChangedFile]
    let repoRoot: String
    var onFileClicked: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    /// Runs a git command silently via Process in the repo, then refreshes.
    var onGitAction: (([String]) -> Void)?
    /// Sends a command to the terminal for visible output (diff, stash list).
    var onTerminalAction: ((String) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onReveal: ((String) -> Void)?

    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true
    @State private var untrackedExpanded = true
    @State private var hoveredFileID: UUID?

    private var stagedFiles: [GitPlugin.GitChangedFile] {
        changedFiles.filter(\.isStaged)
    }

    private var unstagedFiles: [GitPlugin.GitChangedFile] {
        changedFiles.filter { $0.isUnstaged && !$0.isUntracked }
    }

    private var untrackedFiles: [GitPlugin.GitChangedFile] {
        changedFiles.filter(\.isUntracked)
    }

    var body: some View {
        let theme = AppSettings.shared.theme
        let density = AppSettings.shared.sidebarDensity

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Branch header
                branchHeader(theme: theme, density: density)

                // Last commit
                if let commit = lastCommit {
                    Text(commit)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, density == .comfortable ? 12 : 8)
                        .padding(.bottom, 4)
                }

                if !changedFiles.isEmpty {
                    Divider()

                    // Staged changes
                    if !stagedFiles.isEmpty {
                        sectionHeader(
                            title: "Staged Changes",
                            count: stagedFiles.count,
                            color: NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0),
                            expanded: $stagedExpanded,
                            density: density,
                            theme: theme
                        )
                        if stagedExpanded {
                            ForEach(stagedFiles) { file in
                                fileRow(file: file, section: .staged, theme: theme, density: density)
                            }
                        }
                    }

                    // Unstaged changes
                    if !unstagedFiles.isEmpty {
                        sectionHeader(
                            title: "Changes",
                            count: unstagedFiles.count,
                            color: NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0),
                            expanded: $unstagedExpanded,
                            density: density,
                            theme: theme
                        )
                        if unstagedExpanded {
                            ForEach(unstagedFiles) { file in
                                fileRow(file: file, section: .unstaged, theme: theme, density: density)
                            }
                        }
                    }

                    // Untracked files
                    if !untrackedFiles.isEmpty {
                        sectionHeader(
                            title: "Untracked",
                            count: untrackedFiles.count,
                            color: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),
                            expanded: $untrackedExpanded,
                            density: density,
                            theme: theme
                        )
                        if untrackedExpanded {
                            ForEach(untrackedFiles) { file in
                                fileRow(file: file, section: .untracked, theme: theme, density: density)
                            }
                        }
                    }
                } else {
                    Text("Working tree clean")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .padding(.horizontal, density == .comfortable ? 12 : 8)
                        .padding(.vertical, density == .comfortable ? 8 : 6)
                }

                // Stash bar
                if stashCount > 0 {
                    Divider()
                    stashBar(theme: theme, density: density)
                }
            }
        }
    }

    // MARK: - Branch Header

    @ViewBuilder
    private func branchHeader(theme: TerminalTheme, density: SidebarDensity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: theme.accentColor))
            Text(branch)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: theme.accentColor))
            if aheadCount > 0 || behindCount > 0 {
                HStack(spacing: 2) {
                    if aheadCount > 0 {
                        Text("\u{2191}\(aheadCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    if behindCount > 0 {
                        Text("\u{2193}\(behindCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
                .foregroundColor(Color(nsColor: theme.chromeMuted))
            }
            Spacer()
            if !changedFiles.isEmpty {
                Button(action: {
                    onGitAction?(["stash"])
                }) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stash all changes")
            }
            Button(action: { onRefresh?() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: theme.chromeMuted))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh git status")
        }
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, density == .comfortable ? 8 : 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Branch: \(branch)\(changedFiles.isEmpty ? "" : ", \(changedFiles.count) changed files")")
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(
        title: String,
        count: Int,
        color: NSColor,
        expanded: Binding<Bool>,
        density: SidebarDensity,
        theme: TerminalTheme
    ) -> some View {
        Button(action: { expanded.wrappedValue.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(nsColor: theme.chromeMuted))
                    .frame(width: 10)
                Text("\(title) (\(count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: color))
                Spacer()
            }
            .padding(.horizontal, density == .comfortable ? 12 : 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) files, \(expanded.wrappedValue ? "expanded" : "collapsed")")
    }

    // MARK: - File Row

    private enum FileSection {
        case staged, unstaged, untracked
    }

    @ViewBuilder
    private func fileRow(
        file: GitPlugin.GitChangedFile,
        section: FileSection,
        theme: TerminalTheme,
        density: SidebarDensity
    ) -> some View {
        let itemHeight: CGFloat = density == .comfortable ? 26 : 20
        let isHovered = hoveredFileID == file.id
        let escapedPath = RemoteExplorer.shellEscPath(file.path)

        Button(action: { onFileClicked?(file.fullPath) }) {
            HStack(spacing: 6) {
                Image(systemName: file.statusIcon)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: file.statusColor))
                    .frame(width: 14)
                Text(file.status)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(nsColor: file.statusColor))
                    .frame(width: 14)
                Text(file.path)
                    .font(.system(size: density == .comfortable ? 12 : 11))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isHovered {
                    // Inline stage/unstage buttons
                    switch section {
                    case .staged:
                        Button(action: {
                            onGitAction?(["restore", "--staged", file.path])
                        }) {
                            Image(systemName: "minus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(nsColor: theme.chromeMuted))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Unstage \(file.path)")
                    case .unstaged, .untracked:
                        Button(action: {
                            onGitAction?(["add", file.path])
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(nsColor: theme.chromeMuted))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stage \(file.path)")
                    }
                }
            }
            .frame(height: itemHeight)
            .padding(.horizontal, density == .comfortable ? 12 : 8)
            .padding(.leading, 10) // indent under section header
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredFileID = hovering ? file.id : nil
        }
        .contextMenu {
            fileContextMenu(file: file, section: section, escapedPath: escapedPath)
        }
        .accessibilityLabel("\(file.status == "M" ? "Modified" : file.status == "A" ? "Added" : file.status == "D" ? "Deleted" : "Changed"): \(file.path)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func fileContextMenu(
        file: GitPlugin.GitChangedFile,
        section: FileSection,
        escapedPath: String
    ) -> some View {
        switch section {
        case .unstaged, .untracked:
            Button("Stage") {
                onGitAction?(["add", file.path])
            }
        case .staged:
            Button("Unstage") {
                onGitAction?(["restore", "--staged", file.path])
            }
        }

        if section == .unstaged {
            Button("Discard Changes") {
                let alert = NSAlert()
                alert.messageText = "Discard changes to \(file.path)?"
                alert.informativeText = "This cannot be undone."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    onGitAction?(["checkout", "--", file.path])
                }
            }
        }

        Divider()

        if section == .staged {
            Button("Diff (staged)") {
                onTerminalAction?("git diff --cached \(escapedPath)")
            }
        } else if section == .unstaged {
            Button("Diff") {
                onTerminalAction?("git diff \(escapedPath)")
            }
        }

        Divider()

        Button("Copy Path") {
            onCopyPath?(file.path)
        }
        Button("Reveal in Finder") {
            onReveal?(file.fullPath)
        }
    }

    // MARK: - Stash Bar

    @ViewBuilder
    private func stashBar(theme: TerminalTheme, density: SidebarDensity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.2")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: theme.chromeMuted))
            Text("\(stashCount) stash\(stashCount == 1 ? "" : "es")")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: theme.chromeText))
            Spacer()
            Button("Pop") {
                onGitAction?(["stash", "pop"])
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: theme.accentColor))
            Button("List") {
                onTerminalAction?("git stash list")
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: theme.accentColor))
        }
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 6)
    }
}
