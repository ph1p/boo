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
    /// Optional external diff tool command. Supports `{file}` placeholder for the full path.
    /// When nil, falls back to `git diff`.
    var diffTool: String? = nil
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
                            .font(fontScale.font(.base, design: .monospaced))
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
                        .padding(.bottom, density == .comfortable ? 6 : 4)
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

    // MARK: - Diff Command

    /// Returns the shell command to show a diff for `file`.
    /// If a custom `diffTool` is set, uses it (substituting `{file}` with the full path).
    /// Otherwise falls back to `git diff [--cached] <path>`.
    private func diffCommand(for file: GitPlugin.GitChangedFile, section: FileSection) -> String {
        let escapedFull = RemoteExplorer.shellEscPath(file.fullPath)
        if let tool = diffTool, !tool.isEmpty {
            if tool.contains("{file}") {
                return tool.replacingOccurrences(of: "{file}", with: escapedFull)
            }
            return "\(tool) \(escapedFull)"
        }
        let escapedRel = RemoteExplorer.shellEscPath(file.path)
        switch section {
        case .staged: return "git diff --cached \(escapedRel)"
        case .unstaged: return "git diff \(escapedRel)"
        case .untracked: return ""
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
                        .font(fontScale.font(.sm))
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
                        .font(fontScale.font(.sm))
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
                .font(fontScale.font(.base))
                .foregroundColor(Color(nsColor: theme.accentColor))
            Text(branch)
                .font(fontScale.font(.base, design: .monospaced).weight(.medium))
                .foregroundColor(Color(nsColor: theme.accentColor))
                .lineLimit(1)
                .truncationMode(.middle)
            if aheadCount > 0 || behindCount > 0 {
                HStack(spacing: 2) {
                    if aheadCount > 0 {
                        Text("\u{2191}\(aheadCount)")
                            .font(fontScale.font(.base, design: .monospaced).weight(.medium))
                    }
                    if behindCount > 0 {
                        Text("\u{2193}\(behindCount)")
                            .font(fontScale.font(.base, design: .monospaced).weight(.medium))
                    }
                }
                .foregroundColor(Color(nsColor: theme.chromeMuted))
            }
            Spacer()
            Button(action: { onRefresh?() }) {
                Image(systemName: "arrow.clockwise")
                    .font(fontScale.font(.base))
                    .foregroundColor(Color(nsColor: theme.chromeMuted))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh git status")
        }
        .padding(.horizontal, density == .comfortable ? 12 : 8)
        .padding(.vertical, density == .comfortable ? 12 : 8)
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
                        .font(fontScale.font(.sm).weight(.bold))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                        .frame(width: 10)
                    Text("\(title) (\(count))")
                        .font(fontScale.font(.base).weight(.semibold))
                        .foregroundColor(Color(nsColor: color))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            // Bulk action button — shown on hover
            switch section {
            case .staged:
                Button(action: { onGitAction?(["restore", "--staged", "."]) }) {
                    Text("Unstage all")
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Unstage all staged files")
                .accessibilityLabel("Unstage all files")
            case .unstaged:
                Button(action: { onGitAction?(["add", "-u"]) }) {
                    Text("Stage all")
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Stage all modified files")
                .accessibilityLabel("Stage all changed files")
            case .untracked:
                Button(action: { for f in untrackedFiles { onGitAction?(["add", f.path]) } }) {
                    Text("Stage all")
                        .font(fontScale.font(.sm))
                        .foregroundColor(Color(nsColor: theme.chromeMuted))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .help("Stage all untracked files")
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
        let cmd = diffCommand(for: file, section: section)

        HStack(spacing: 0) {
            // Left area as a Button — Spacer inside label so hit area fills available
            // width; right-group buttons are siblings so they take gesture priority.
            Button {
                switch section {
                case .staged, .unstaged: onTerminalAction?(cmd)
                case .untracked: onFileClicked?(file.fullPath)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(file.status)
                        .font(fontScale.font(.base, design: .monospaced).weight(.bold))
                        .foregroundColor(Color(nsColor: file.statusColor))
                        .frame(width: 14, alignment: .center)
                    Text((file.path as NSString).lastPathComponent)
                        .font(fontScale.font(.base))
                        .foregroundColor(Color(nsColor: theme.chromeText))
                        .lineLimit(1)
                    if !(file.path as NSString).deletingLastPathComponent.isEmpty {
                        Text((file.path as NSString).deletingLastPathComponent)
                            .font(fontScale.font(.sm))
                            .foregroundColor(Color(nsColor: theme.chromeMuted))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Right action buttons — peer siblings, not children of the left button.
            // Both hidden at rest (opacity 0), revealed on row hover.
            HStack(spacing: 8) {
                if section != .untracked {
                    Button {
                        onTerminalAction?(cmd)
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(fontScale.font(.sm))
                            .foregroundColor(Color(nsColor: theme.chromeMuted))
                            .frame(minWidth: 20, minHeight: 20)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 0.7 : 0)
                    .help("Show diff")
                }
                switch section {
                case .staged:
                    Button {
                        onGitAction?(["restore", "--staged", file.path])
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(fontScale.font(.base))
                            .foregroundColor(Color(nsColor: theme.chromeMuted))
                            .frame(minWidth: 20, minHeight: 20)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1.0 : 0)
                    .help("Unstage")
                    .accessibilityLabel("Unstage \(file.path)")
                case .unstaged, .untracked:
                    Button {
                        onGitAction?(["add", file.path])
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(fontScale.font(.base))
                            .foregroundColor(Color(nsColor: theme.chromeMuted))
                            .frame(minWidth: 20, minHeight: 20)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1.0 : 0)
                    .help("Stage")
                    .accessibilityLabel("Stage \(file.path)")
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: itemHeight)
        .padding(.horizontal, density == .comfortable ? 4 : 2)
        .padding(.leading, density == .comfortable ? 16 : 12)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: isHovered ? theme.sidebarRowHover : .clear))
        )
        .padding(.horizontal, density == .comfortable ? 8 : 6)
        .onHover { hovering in
            hoveredFileID = hovering ? file.id : nil
        }
        .contextMenu {
            fileContextMenu(file: file, section: section)
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
        section: FileSection
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

        if section == .staged || section == .unstaged {
            Button(section == .staged ? "Diff (staged)" : "Diff") {
                onTerminalAction?(diffCommand(for: file, section: section))
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
