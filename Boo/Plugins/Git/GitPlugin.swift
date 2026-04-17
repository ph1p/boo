import SwiftUI

/// Built-in git plugin. Enriches context with git branch/dirty state,
/// provides status bar segment and detail panel with changed files.
@MainActor
final class GitPlugin: BooPluginProtocol {
    let manifest = PluginManifest(
        id: "git-panel",
        name: "Git",
        version: "1.0.0",
        icon: "arrow.triangle.branch",
        description: "Git branch, status, and changed files",
        when: "git.active && !remote && !process.ai",
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: true, sidebarTab: true),
        statusBar: PluginManifest.StatusBarManifest(position: "left", priority: 15, template: nil),
        settings: [
            PluginManifest.SettingManifest(
                key: "showBranch", type: .bool, label: "Show git branch in status bar",
                defaultValue: AnyCodableValue(true), options: nil),
            PluginManifest.SettingManifest(
                key: "diffTool", type: .string,
                label: "Diff tool",
                defaultValue: AnyCodableValue(""), options: "gitDiffTool")
        ]
    )

    var prefersOuterScrollView: Bool { true }

    var subscribedEvents: Set<PluginEvent> { [.cwdChanged, .focusChanged] }

    /// Cached changed files per repo root.
    var cachedFiles: [GitChangedFile] = []

    /// Current changed file count for status bar.
    var changedFileCount: Int { cachedFiles.count }
    var lastRefreshedPath: String?
    var gitDirWatcher: FileSystemWatcher?
    /// Watches working tree for file edits (create/modify/delete), so status updates without
    /// needing a CWD change.
    var workTreeWatcher: FileSystemWatcher?
    /// Watches CWD when no repo is active, to detect `git init`.
    var cwdWatcher: FileSystemWatcher?
    var watchedRepoRoot: String?
    var debounceWork: DispatchWorkItem?

    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?
    /// Called when the detected branch or repo root changes (e.g. after git switch).
    /// Lets the host update its branch cache without waiting for a CWD change event.
    var onBranchChanged: ((_ branch: String?, _ repoRoot: String?) -> Void)?

    /// Cached branch name, kept in sync with .git/HEAD by refreshGitStatus.
    var cachedBranch: String?
    var cachedRepoRoot: String?

    /// Cached extended git info.
    var cachedAheadCount: Int = 0
    var cachedBehindCount: Int = 0
    var cachedLastCommit: String?
    var cachedRemotes: [GitRemote] = []

    struct GitChangedFile: Identifiable {
        let id: UUID
        let path: String
        let indexStatus: Character  // column 1: staged status
        let workTreeStatus: Character  // column 2: work tree status
        let fullPath: String

        init(path: String, indexStatus: Character, workTreeStatus: Character, fullPath: String) {
            self.id = UUID()
            self.path = path
            self.indexStatus = indexStatus
            self.workTreeStatus = workTreeStatus
            self.fullPath = fullPath
        }

        /// Copy with new status columns, preserving path/fullPath/id.
        func withStatus(index: Character, workTree: Character) -> GitChangedFile {
            GitChangedFile(path: path, indexStatus: index, workTreeStatus: workTree, fullPath: fullPath)
        }

        /// Legacy single-char status for display.
        var status: String {
            if indexStatus == "?" { return "?" }
            if indexStatus != " " && indexStatus != "?" { return String(indexStatus) }
            return String(workTreeStatus)
        }

        /// Whether this file has staged changes.
        var isStaged: Bool {
            indexStatus != " " && indexStatus != "?"
        }

        /// Whether this file has unstaged work-tree changes.
        var isUnstaged: Bool {
            workTreeStatus != " " && workTreeStatus != "?"
        }

        /// Whether this file is untracked.
        var isUntracked: Bool {
            indexStatus == "?" && workTreeStatus == "?"
        }

        var statusColor: NSColor {
            switch status {
            case "M": return NSColor(calibratedRed: 0.9, green: 0.66, blue: 0.2, alpha: 1.0)
            case "A": return NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.31, alpha: 1.0)
            case "D": return NSColor(calibratedRed: 0.97, green: 0.32, blue: 0.29, alpha: 1.0)
            default: return NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            }
        }

    }

    // MARK: - Enrich

    func enrich(context: EnrichmentContext) {
        if !cachedFiles.isEmpty {
            context.gitIsDirty = true
            context.gitChangedFileCount = cachedFiles.count
        }
        context.gitStagedCount = cachedFiles.filter(\.isStaged).count
        context.gitAheadCount = cachedAheadCount
        context.gitBehindCount = cachedBehindCount
        context.gitLastCommitShort = cachedLastCommit
    }

    // MARK: - Status Bar

    func makeStatusBarContent(context: PluginContext) -> StatusBarContent? {
        guard let git = context.terminal.gitContext else { return nil }
        var text = git.branch
        if git.aheadCount > 0 || git.behindCount > 0 {
            var arrow = ""
            if git.aheadCount > 0 { arrow += "^\(git.aheadCount)" }
            if git.behindCount > 0 { arrow += "v\(git.behindCount)" }
            text += " " + arrow
        }
        let count = git.changedFileCount > 0 ? git.changedFileCount : cachedFiles.count
        if count > 0 {
            text += ", \(count) changed"
        }
        return StatusBarContent(
            text: text,
            icon: "arrow.triangle.branch",
            tint: !cachedFiles.isEmpty ? .warning : .success,
            accessibilityLabel: "Git: \(text)"
        )
    }

    // MARK: - Detail View

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard let git = context.terminal.gitContext else { return nil }
        let repoRoot = git.repoRoot
        let act = actions
        let diffTool = AppSettings.shared.pluginString("git-panel", "diffTool", default: "")
        return AnyView(
            GitDetailView(
                branch: git.branch,
                aheadCount: git.aheadCount,
                behindCount: git.behindCount,
                lastCommit: git.lastCommitShort,
                changedFiles: cachedFiles,
                remotes: cachedRemotes,
                repoRoot: repoRoot,
                onFileClicked: { path in
                    act?.handle(DSLAction(type: "open", path: path, command: nil, text: nil))
                },
                onRefresh: { [weak self] in
                    self?.refreshGitStatus(cwd: repoRoot, repoRoot: repoRoot)
                },
                onGitAction: { [weak self] args in
                    guard let self else { return }
                    // Optimistic update — mutate cachedFiles immediately for instant UI feedback.
                    self.applyOptimisticGitAction(args: args)
                    self.onRequestCycleRerun?()
                    // Background: run the real command, then do a full refresh to confirm.
                    DispatchQueue.global(qos: .userInitiated).async {
                        Self.runGitCommand(repoRoot: repoRoot, args: args)
                        DispatchQueue.main.async {
                            self.refreshGitStatus(cwd: repoRoot, repoRoot: repoRoot)
                        }
                    }
                },
                onTerminalAction: { command in
                    act?.handle(DSLAction(type: "exec", path: nil, command: command, text: nil))
                },
                diffTool: diffTool.isEmpty ? nil : diffTool,
                onCopyPath: { path in
                    act?.handle(DSLAction(type: "copy", path: path, command: nil, text: nil))
                },
                onReveal: { path in
                    act?.handle(DSLAction(type: "reveal", path: path, command: nil, text: nil))
                },
                fontScale: context.fontScale
            ))
    }

    // MARK: - Lifecycle

    func cwdChanged(newPath: String, context: TerminalContext) {
        debugLog("[Git] cwdChanged: newPath=\(newPath) repoRoot=\(context.gitContext?.repoRoot ?? "nil")")
        refreshGitStatus(cwd: newPath, repoRoot: context.gitContext?.repoRoot)
    }

    func terminalFocusChanged(terminalID: UUID, context: TerminalContext) {
        debugLog(
            "[Git] terminalFocusChanged: cwd=\(context.cwd) repoRoot=\(context.gitContext?.repoRoot ?? "nil") branch=\(context.gitContext?.branch ?? "nil")"
        )
        refreshGitStatus(cwd: context.cwd, repoRoot: context.gitContext?.repoRoot)
    }

    // MARK: - Optimistic Updates

    /// Apply an immediate local mutation to `cachedFiles` based on the git command args,
    /// so the UI reflects the action before the background git process completes.
    func applyOptimisticGitAction(args: [String]) {
        guard args.count >= 2 else { return }
        switch args[0] {
        case "add":
            let target = args[1]
            if target == "-u" {
                // Stage all unstaged (tracked) files
                cachedFiles = cachedFiles.map { f in
                    f.isUnstaged && !f.isUntracked
                        ? f.withStatus(index: f.workTreeStatus, workTree: " ")
                        : f
                }
            } else {
                // Stage a single file
                cachedFiles = cachedFiles.map { f in
                    guard f.path == target else { return f }
                    if f.isUntracked {
                        return f.withStatus(index: "A", workTree: " ")
                    } else if f.isUnstaged {
                        return f.withStatus(index: f.workTreeStatus, workTree: " ")
                    }
                    return f
                }
            }
        case "restore":
            guard args.count >= 3, args[1] == "--staged" else { return }
            let target = args[2]
            if target == "." {
                // Unstage all staged files
                cachedFiles = cachedFiles.map { f in
                    guard f.isStaged else { return f }
                    // A file staged as new (A) with no work-tree counterpart reverts to untracked
                    if f.indexStatus == "A" && f.workTreeStatus == " " {
                        return f.withStatus(index: "?", workTree: "?")
                    }
                    return f.withStatus(index: " ", workTree: f.indexStatus)
                }
            } else {
                // Unstage a single file
                cachedFiles = cachedFiles.map { f in
                    guard f.path == target, f.isStaged else { return f }
                    // A file staged as new (A) with no work-tree counterpart reverts to untracked
                    if f.indexStatus == "A" && f.workTreeStatus == " " {
                        return f.withStatus(index: "?", workTree: "?")
                    }
                    return f.withStatus(index: " ", workTree: f.indexStatus)
                }
            }
        case "checkout":
            guard args.count >= 3, args[1] == "--" else { return }
            let target = args[2]
            cachedFiles = cachedFiles.filter { $0.path != target }
        default:
            break
        }
    }
}
