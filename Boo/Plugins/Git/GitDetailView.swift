import SwiftUI

// MARK: - Git Detail View

struct GitDetailView: View {
    let branch: String
    let aheadCount: Int
    let behindCount: Int
    let lastCommit: String?
    let changedFiles: [GitPlugin.GitChangedFile]
    let remotes: [GitPlugin.GitRemote]
    let repoRoot: String
    var onFileClicked: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    /// Runs a git command silently via Process in the repo, then refreshes.
    var onGitAction: (([String]) -> Void)?
    /// Sends a command to the terminal for visible output (diff).
    var onTerminalAction: ((String) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onReveal: ((String) -> Void)?
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true
    @State private var untrackedExpanded = true
    @State private var hoveredFileID: UUID?
    @State private var hoveredSection: FileSection?
    @State private var commitCopied = false

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
                    Button(action: {
                        let hash = String(commit.prefix(while: { !$0.isWhitespace }))
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hash, forType: .string)
                        commitCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            commitCopied = false
                        }
                    }) {
                        Text(commitCopied ? "Copied!" : commit)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(
                                Color(nsColor: commitCopied ? theme.accentColor : theme.chromeMuted)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy commit hash")
                    .accessibilityLabel("Copy commit hash")
                    .padding(.horizontal, density == .comfortable ? 12 : 8)
                    .padding(.bottom, 4)
                }

                // Remotes
                if !remotes.isEmpty {
                    remotesSection(theme: theme, density: density)
                }

                if !changedFiles.isEmpty {
                    Divider()

                    // Staged changes
                    if !stagedFiles.isEmpty {
                        sectionHeader(
                            title: "Staged Changes",
                            count: stagedFiles.count,
                            color: NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0),
                            section: .staged,
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
                            section: .unstaged,
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
                            section: .untracked,
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
                        .font(fontScale.font(.base))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .padding(.horizontal, density == .comfortable ? 12 : 8)
                        .padding(.vertical, density == .comfortable ? 8 : 6)
                }

            }
        }
    }

    // MARK: - Remotes

    @ViewBuilder
    private func remotesSection(theme: TerminalTheme, density: SidebarDensity) -> some View {
        let hPad: CGFloat = density == .comfortable ? 12 : 8
        ForEach(remotes, id: \.name) { remote in
            if let webURL = remote.webURL {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                    Text(remote.name)
                        .font(fontScale.font(.base).weight(Font.Weight.medium))
                        .foregroundColor(Color(nsColor: theme.accentColor))
                    Text(webURL.host ?? remote.url)
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(webURL) }
                .help(remote.url)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                    Text(remote.name)
                        .font(fontScale.font(.base).weight(Font.Weight.medium))
                        .foregroundColor(Color(nsColor: theme.chromeText))
                    Text(remote.url)
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 2)
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
        .accessibilityLabel(
            "Branch: \(branch)\(changedFiles.isEmpty ? "" : ", \(changedFiles.count) changed files")")
    }

    // MARK: - Section Header

    private enum FileSection {
        case staged, unstaged, untracked
    }

    @ViewBuilder
    private func sectionHeader(
        title: String,
        count: Int,
        color: NSColor,
        section: FileSection,
        expanded: Binding<Bool>,
        density: SidebarDensity,
        theme: TerminalTheme
    ) -> some View {
        let isHovered = hoveredSection == section
        HStack(spacing: 4) {
            Button(action: { expanded.wrappedValue.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .frame(width: 10)
                    Text("\(title) (\(count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: color))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            // Bulk action buttons
            switch section {
            case .staged:
                Button(action: {
                    onGitAction?(["restore", "--staged", "."])
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Unstage all")
                .accessibilityLabel("Unstage all files")
            case .unstaged:
                Button(action: {
                    onGitAction?(["add", "-u"])
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Stage all changes")
                .accessibilityLabel("Stage all changed files")
            case .untracked:
                Button(action: {
                    for file in untrackedFiles {
                        onGitAction?(["add", file.path])
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Stage all untracked")
                .accessibilityLabel("Stage all untracked files")
            }
        }
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredSection = hovering ? section : nil
        }
        .accessibilityLabel(
            "\(title), \(count) files, \(expanded.wrappedValue ? "expanded" : "collapsed")")
    }

    // MARK: - File Row

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

        Button(action: {
            // Click = show diff in terminal
            switch section {
            case .staged:
                onTerminalAction?("git diff --cached \(escapedPath)")
            case .unstaged:
                onTerminalAction?("git diff \(escapedPath)")
            case .untracked:
                onFileClicked?(file.fullPath)
            }
        }) {
            HStack(spacing: 6) {
                Text(file.status)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(nsColor: file.statusColor))
                    .frame(width: 14, alignment: .center)
                Text((file.path as NSString).lastPathComponent)
                    .font(fontScale.font(.base))
                    .foregroundColor(Color(nsColor: theme.chromeText))
                    .lineLimit(1)
                if (file.path as NSString).deletingLastPathComponent.count > 0 {
                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(fontScale.font(.xs))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                // Inline stage/unstage buttons — always present, opacity changes on hover
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
                    .opacity(isHovered ? 1.0 : 0.3)
                    .help("Unstage")
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
                    .opacity(isHovered ? 1.0 : 0.3)
                    .help("Stage")
                    .accessibilityLabel("Stage \(file.path)")
                }
            }
            .frame(height: itemHeight)
            .padding(.horizontal, density == .comfortable ? 12 : 8)
            .padding(.leading, 10)  // indent under section header
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredFileID = hovering ? file.id : nil
        }
        .contextMenu {
            fileContextMenu(file: file, section: section, escapedPath: escapedPath)
        }
        .accessibilityLabel(
            "\(file.status == "M" ? "Modified" : file.status == "A" ? "Added" : file.status == "D" ? "Deleted" : "Changed"): \(file.path)"
        )
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

        Button("Open File") {
            onFileClicked?(file.fullPath)
        }

        Button("Copy Path") {
            onCopyPath?(file.path)
        }

        Button("Reveal in Finder") {
            onReveal?(file.fullPath)
        }

        if section == .untracked {
            Divider()
            Button("Add to .gitignore") {
                let gitignorePath = (repoRoot as NSString).appendingPathComponent(".gitignore")
                let entry = file.path + "\n"
                if FileManager.default.fileExists(atPath: gitignorePath) {
                    if let handle = FileHandle(forWritingAtPath: gitignorePath) {
                        handle.seekToEndOfFile()
                        if let data = entry.data(using: .utf8) {
                            handle.write(data)
                        }
                        handle.closeFile()
                    }
                } else {
                    try? entry.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
                }
                onRefresh?()
            }
        }

        if section == .unstaged {
            Divider()
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
    }

}
