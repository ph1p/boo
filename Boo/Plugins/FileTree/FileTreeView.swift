import SwiftUI
import UniformTypeIdentifiers

// MARK: - Actions

struct FileTreeActions: @unchecked Sendable {
    var onFileClicked: (@MainActor (String) -> Void)?
    var onPastePath: (@MainActor (String) -> Void)?
    /// Open a directory as a terminal tab
    var onOpenInTab: (@MainActor (String) -> Void)?
    /// Open a directory as a terminal pane (split)
    var onOpenInPane: (@MainActor (String) -> Void)?
    /// Open a file in a new editor/viewer tab
    var onOpenFileInTab: (@MainActor (String) -> Void)?
    /// Open a file in a new editor/viewer pane (split)
    var onOpenFileInPane: (@MainActor (String) -> Void)?
    /// Open an HTML file directly in a browser tab
    var onOpenFileInBrowser: (@MainActor (String) -> Void)?
    var onCopyPath: (@MainActor (String) -> Void)?
    var onRevealInFinder: (@MainActor (String) -> Void)?
    var onRunCommand: (@MainActor (String) -> Void)?
    var onNavigate: (@MainActor (String) -> Void)?
    /// Show a folder as the explorer root without touching the shell. Set by `FileTreeView`
    /// from its navigation, so it acts on the terminal the view was built for.
    var onBrowse: (@MainActor (String) -> Void)?
    /// Trash one or more paths (the multi-selection); the view confirms first.
    var onMoveToTrash: (@MainActor ([String]) -> Void)?
    /// Rename in place; `done` gets the new path, or nil when it failed.
    var onRename: (@MainActor (_ oldPath: String, _ newName: String, _ done: @escaping Done) -> Void)?
    var onMove: (@MainActor (_ sourcePath: String, _ destinationDir: String) -> Void)?
    /// Create a folder or file at `relativePath` (a `FileTreeNaming` target, so it may
    /// contain "/" for missing folders) inside `parentPath`; `done` gets the created path.
    var onCreateFolder: (@MainActor (_ parentPath: String, _ relativePath: String, _ done: @escaping Done) -> Void)?
    var onCreateFile: (@MainActor (_ parentPath: String, _ relativePath: String, _ done: @escaping Done) -> Void)?
    /// Copy next to the original; `done` gets the copy's path.
    var onDuplicate: (@MainActor (_ path: String, _ done: @escaping Done) -> Void)?
    var onCopyImage: (@MainActor (String) -> Void)?
    var onReferenceInAI: (@MainActor (String) -> Void)?
    var onSetFileRoot: (@MainActor (String) -> Void)?
    /// Open a file with its default macOS app (a remote file is fetched first).
    var onOpenExternally: (@MainActor (String) -> Void)?
    /// Save files to this Mac (remote trees).
    var onDownload: (@MainActor ([String]) -> Void)?
    /// Copy files dropped from Finder into a folder (remote trees). Without it a Finder
    /// drop moves the file via `onMove`.
    var onUpload: (@MainActor (_ localPaths: [String], _ destinationDir: String) -> Void)?
    /// Delete permanently — offered when there is no trash (remote trees).
    var onDelete: (@MainActor ([String]) -> Void)?
    /// Manual refresh: the view re-reads every expanded folder itself, then calls this
    /// with the root path so the plugin can refresh what else it owns (git status).
    var onRefresh: (@MainActor (_ rootPath: String) -> Void)?
    /// One-line size/date summary for the hover tooltip, or nil when unavailable.
    var onFetchInfo: (@MainActor (String) async -> String?)?
    var isAIAgentRunning: Bool = false

    /// Completion of a file operation: the resulting path, or nil when it failed (the
    /// plugin has already told the user why).
    typealias Done = @MainActor (String?) -> Void

    /// Whether rows offer removal at all, and whether it goes to the Trash.
    var canRemove: Bool { onMoveToTrash != nil || onDelete != nil }
    /// Remove goes to the Trash (local) rather than deleting outright (remote).
    var removesToTrash: Bool { onMoveToTrash != nil }

    /// Whether an AI agent holds the foreground — row actions differ, so both file-tree
    /// plugins bake it into their section generation as well as into the actions.
    @MainActor
    static func isAIAgentContext(_ context: PluginContext) -> Bool {
        ProcessIcon.category(for: context.terminal.processName) == "ai"
    }
}

/// Hover-tooltip summary shared by the local and remote trees.
enum FileTreeInfo {
    static func summary(size: Int64?, modified: Date?) -> String? {
        var parts: [String] = []
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified { parts.append("Modified " + modified.formatted(date: .abbreviated, time: .shortened)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Shared State

/// Inline editing state — renaming a row, or naming a not-yet-created item in a draft
/// row — lifted out of per-row @State so it survives row rebuilds.
@MainActor final class FileTreeRenameState: ObservableObject {
    /// A file or folder being named in place before it exists on disk.
    struct Draft: Equatable {
        let parentPath: String
        let isDirectory: Bool
    }

    @Published var renamingPath: String?
    @Published var draft: Draft?
    @Published var renameText: String = ""

    var isEditing: Bool { renamingPath != nil || draft != nil }

    // The short delay lets a closing context menu hand focus back before the field
    // appears and takes it.
    func beginRename(path: String, currentName: String) {
        draft = nil
        renameText = currentName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.renamingPath = path
        }
    }

    func beginCreate(in parentPath: String, isDirectory: Bool) {
        renamingPath = nil
        renameText = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.draft = Draft(parentPath: parentPath, isDirectory: isDirectory)
        }
    }

    func cancel() {
        renamingPath = nil
        draft = nil
    }

    func commit(actions: FileTreeActions) {
        guard let path = renamingPath else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renamingPath = nil
        let currentName = (path as NSString).lastPathComponent
        if !newName.isEmpty && newName != currentName {
            actions.onRename?(path, newName) { _ in }
        }
    }

    /// End the draft and return what to create, or nil when the name was left empty
    /// (Escape, or focus moved away without typing).
    func commitDraft() -> (draft: Draft, name: String)? {
        guard let draft else { return nil }
        self.draft = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (draft, name)
    }
}

// MARK: - FileTreeView

struct FileTreeView: View {
    @ObservedObject var root: FileTreeNode
    @ObservedObject var settings = SettingsObserver(topics: [.theme, .explorer, .sidebarFont, .appFont, .plugins])
    @StateObject private var renameState = FileTreeRenameState()
    @StateObject private var dragState = FileTreeDragState()
    @StateObject private var selection = FileTreeSelection()
    @StateObject private var filter = FileTreeFilterModel()
    @FocusState private var treeFocused: Bool
    @FocusState private var filterFocused: Bool
    /// Paths awaiting confirmation for Move to Trash (or Delete without a trash).
    @State private var pendingTrash: [String] = []
    @State private var typeAhead = ""
    @State private var typeAheadAt = Date.distantPast
    @State private var rowCache = FileTreeRowCache()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var sticky = FileTreeStickyState()
    var actions: FileTreeActions
    /// Back/forward/up and terminal linking; nil hides the navigation bar.
    var navigation: FileTreeNavigation? = nil
    @Environment(\.windowTheme) private var windowTheme

    var body: some View {
        let _ = settings.revision
        let _ = root.treeRevision
        let theme = windowTheme ?? AppSettings.shared.theme
        let cfg = RowStyle(
            showIcons: AppSettings.shared.explorerIconsEnabled,
            fontSize: AppSettings.shared.sidebarFontSize,
            font: explorerFont,
            textColor: Color(nsColor: theme.textPrimary),
            mutedColor: Color(nsColor: theme.textMuted),
            accentColor: Color(nsColor: theme.accent),
            hoverColor: Color(nsColor: theme.hoverFill),
            selectionColor: Color(nsColor: theme.accentSelectionFill),
            inactiveSelectionColor: Color(nsColor: theme.controlFill),
            controlFill: Color(nsColor: theme.subtleFill),
            successColor: Color(nsColor: theme.success),
            warningColor: Color(nsColor: theme.warning),
            errorColor: Color(nsColor: theme.error)
        )
        let showHidden = AppSettings.shared.showHiddenFiles
        let git = AppSettings.shared.explorerGitDecorations ? root.gitStatus : nil
        let flat = filter.isActive ? nil : rowCache.rows(for: root, showHidden: showHidden)
        let rows = flat?.rows ?? []
        let order = flat?.order ?? filter.matches.map { absolutePath($0.entry) }
        let stickyFolders = AppSettings.shared.explorerStickyFolders && !filter.isActive

        VStack(alignment: .leading, spacing: 0) {
            if let navigation, AppSettings.shared.explorerShowNavigationBar {
                FileTreeNavigationBar(navigation: navigation, rootPath: root.path, style: cfg)
            }
            if AppSettings.shared.explorerShowFilterBar {
                FileTreeFilterBar(
                    filter: filter, focused: $filterFocused, style: cfg,
                    onCollapseAll: { root.collapseAll() },
                    onRefresh: refreshAction,
                    onSubmit: { activateFirstMatch() },
                    onMoveIntoTree: {
                        treeFocused = true
                        selection.move(by: 1, order: order, extend: false)
                    }
                )
            }

            // The tree scrolls itself so the LazyVStack only builds the rows on screen
            // (inside the sidebar's outer NSScrollView every row was built and re-diffed).
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Group {
                        if filter.isActive {
                            filterResults(cfg: cfg, git: git, order: order)
                        } else {
                            tree(rows: rows, cfg: cfg, git: git, order: order)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .overlay(alignment: .top) {
                    if stickyFolders {
                        FileTreeStickyHeader(
                            state: sticky, rows: rows, style: cfg, git: git,
                            background: Color(nsColor: theme.chromeSidebarFill),
                            separator: Color(nsColor: theme.separator),
                            onSelect: { row in revealPinned(row, rows: rows, proxy: proxy) }
                        )
                    }
                }
                .id(ObjectIdentifier(root))
                .scrollPosition($scrollPosition)
                .onScrollTargetVisibilityChange(idType: String.self) { ids in
                    guard stickyFolders else { return }
                    sticky.update(topIndex: ids.lazy.compactMap { rowCache.index(of: $0) }.min() ?? 0)
                }
                .onScrollGeometryChange(for: CGFloat.self) {
                    $0.contentOffset.y
                } action: { _, y in
                    root.scrollOffset = y
                }
                .onAppear { scrollPosition.scrollTo(y: root.scrollOffset) }
                .onChange(of: selection.cursor) { _, cursor in
                    guard let cursor else { return }
                    scrollToCursor(cursor, rows: rows, stickyFolders: stickyFolders, proxy: proxy)
                }
            }
            // Ideal height only seeds the sidebar's initial split; the panel sizes it after.
            .frame(minHeight: 0, idealHeight: estimatedHeight(rowCount: rows.count, style: cfg))
            .focusable()
            .focused($treeFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { handleKey($0, rows: rows, order: order) }
            .onCopyCommand { copyProviders(order: order) }
            .onCommand(#selector(NSResponder.selectAll(_:))) { selection.selectAll(order: order) }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: theme.chromeSidebarFill))
        .contentShape(Rectangle())
        .contextMenu {
            if actions.onCreateFile != nil {
                Button("New File") { startCreate(in: root.path, isDirectory: false) }
            }
            if actions.onCreateFolder != nil {
                Button("New Folder") { startCreate(in: root.path, isDirectory: true) }
            }
            Divider()
            if let refreshAction {
                Button("Refresh") { refreshAction() }
            }
            Button("Collapse All Folders") { root.collapseAll() }
        }
        .onDrop(
            of: fileTreeDropTypes,
            delegate: RootDropDelegate(
                dragState: dragState, actions: actions, rootPath: root.path
            )
        )
        .confirmationDialog(
            trashTitle, isPresented: trashBinding, titleVisibility: .visible
        ) {
            Button(actions.removesToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                if let onMoveToTrash = actions.onMoveToTrash {
                    onMoveToTrash(pendingTrash)
                } else {
                    actions.onDelete?(pendingTrash)
                }
                pendingTrash = []
            }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        }
        // The plugin loads the root before handing it over; only load here when this
        // view was handed a root that has never been read (nil children), so a real
        // install doesn't re-walk the directory a second time.
        .onAppear {
            if root.children == nil { root.loadChildrenAsync() }
            filter.configure(rootPath: root.path, showHidden: showHidden, source: root.source)
        }
        .onChange(of: root.path) { _, path in
            selection.clear()
            renameState.cancel()
            filter.configure(rootPath: path, showHidden: AppSettings.shared.showHiddenFiles, source: root.source)
        }
        .onChange(of: showHidden) { _, hidden in
            filter.configure(rootPath: root.path, showHidden: hidden, source: root.source)
        }
        .onChange(of: root.contentRevision) { _, _ in filter.invalidate() }
        .onChange(of: order) { _, newOrder in selection.prune(visible: newOrder) }
    }

    // MARK: Tree

    @ViewBuilder
    private func tree(rows: [FlatRow], cfg: RowStyle, git: FileTreeGitStatus?, order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The navigation bar's ↑ replaces the `..` row; keep it only without a bar.
            if navigation == nil, root.path != "/" {
                ParentDirectoryButton(style: cfg) { goUp() }
            }

            // Multi-selection in row order, computed once for every row's context menu.
            let selectedInOrder = selection.selected.count > 1 ? selection.ordered(in: order) : []
            LazyVStack(alignment: .leading, spacing: 0) {
                if let draft = renameState.draft, draft.parentPath == root.path {
                    draftRow(draft, depth: 0, cfg: cfg)
                }
                if rows.isEmpty, root.children != nil {
                    FileTreePlaceholderRow(
                        text: root.loadFailed ? "Can't read folder" : "Empty folder", depth: 0, style: cfg,
                        onRetry: root.loadFailed ? refreshAction : nil)
                }
                ForEach(rows) { row in
                    let path = row.node.path
                    if let placeholder = row.placeholder {
                        FileTreePlaceholderRow(
                            text: placeholder == .failed ? "Can't read folder" : "Empty folder", depth: row.depth,
                            style: cfg, onRetry: nil)
                    } else {
                        FileTreeRowView(
                            node: row.node, depth: row.depth, parentPath: row.parentPath,
                            actions: rowActions, renameState: renameState, dragState: dragState,
                            dropLineAbove: dragState.dropPosition == .abovePath(path),
                            isDropTarget: dragState.dropPosition == .onFolder(path),
                            isDragged: dragState.draggedPath == path,
                            style: cfg, rootPath: root.path,
                            isSelected: selection.contains(path),
                            treeFocused: treeFocused,
                            gitStatus: git?.status(for: path, isDirectory: row.node.isDirectory),
                            dimIgnored: AppSettings.shared.explorerDimIgnored,
                            menuPaths: !selectedInOrder.isEmpty && selection.contains(path) ? selectedInOrder : [path],
                            onClick: { kind in click(row.node, kind: kind, order: order) },
                            onTrash: { pendingTrash = $0 },
                            onCreate: { startCreate(in: $0, isDirectory: $1) }
                        )
                        // A draft item sits first under the folder it is created in.
                        if let draft = renameState.draft, draft.parentPath == path,
                            row.node.isDirectory, row.node.isExpanded
                        {
                            draftRow(draft, depth: row.depth + 1, cfg: cfg)
                        }
                    }
                }
            }
            // Row ids feed the sticky header's "first row in view".
            .scrollTargetLayout()
            .padding(.top, 6)
        }
    }

    // MARK: Filter Results

    @ViewBuilder
    private func filterResults(cfg: RowStyle, git: FileTreeGitStatus?, order: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if filter.matches.isEmpty && !filter.isIndexing {
                Text("No matches")
                    .font(cfg.font)
                    .foregroundStyle(cfg.mutedColor)
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
            }
            ForEach(filter.matches, id: \.entry.relativePath) { match in
                let path = absolutePath(match.entry)
                FileTreeMatchRowView(
                    match: match, absolutePath: path, style: cfg,
                    isSelected: selection.contains(path),
                    treeFocused: treeFocused,
                    gitStatus: git?.status(for: path, isDirectory: match.entry.isDirectory),
                    onClick: { kind in
                        focusTreeUnlessOpening(kind, isDirectory: match.entry.isDirectory)
                        selection.click(path, kind: kind, order: order)
                        if kind == .plain { activate(match.entry) }
                    },
                    onReveal: { reveal(path) },
                    actions: rowActions
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private var explorerFont: Font {
        SidebarFontScale(base: AppSettings.shared.sidebarFontSize).font(.base)
    }

    private var trashTitle: String {
        let subject =
            pendingTrash.count == 1
            ? "\"\((pendingTrash.first.map { ($0 as NSString).lastPathComponent } ?? ""))\""
            : "\(pendingTrash.count) items"
        return actions.removesToTrash ? "Move \(subject) to Trash?" : "Delete \(subject)? This can't be undone."
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })
    }

    private func absolutePath(_ entry: FileTreeIndexEntry) -> String {
        (root.path as NSString).appendingPathComponent(entry.relativePath)
    }

    /// Opening a file hands focus to its tab; grabbing it here would steal it back.
    private func focusTreeUnlessOpening(_ kind: FileTreeSelection.ClickKind, isDirectory: Bool) {
        if kind != .plain || isDirectory { treeFocused = true }
    }

    private func click(_ node: FileTreeNode, kind: FileTreeSelection.ClickKind, order: [String]) {
        guard renameState.renamingPath != node.path else { return }
        focusTreeUnlessOpening(kind, isDirectory: node.isDirectory)
        selection.click(node.path, kind: kind, order: order)
        guard kind == .plain else { return }
        if node.isDirectory {
            setExpanded(node, !node.isExpanded)
        } else {
            actions.onFileClicked?(node.path)
        }
    }

    private func setExpanded(_ node: FileTreeNode, _ expanded: Bool) {
        guard node.isDirectory, node.isExpanded != expanded else { return }
        if expanded { node.expand() } else { node.collapse() }
    }

    private func activate(_ entry: FileTreeIndexEntry) {
        let path = absolutePath(entry)
        if entry.isDirectory {
            reveal(path)
        } else {
            actions.onFileClicked?(path)
        }
    }

    private func activateFirstMatch() {
        guard filter.isActive else { return }
        if let cursor = selection.cursor, let match = filter.matches.first(where: { absolutePath($0.entry) == cursor })
        {
            activate(match.entry)
        } else if let first = filter.matches.first {
            activate(first.entry)
        }
    }

    /// Leave filter mode and show `path` in the tree, selected.
    private func reveal(_ path: String) {
        filter.clear()
        treeFocused = true
        // Select once the folders are listed, or pruning against the not-yet-visible
        // rows would drop the selection again.
        root.reveal(path) { _ in selection.select(path) }
    }

    /// Manual refresh, offered when the plugin opts in via `onRefresh`.
    private var refreshAction: (@MainActor () -> Void)? {
        guard let onRefresh = actions.onRefresh else { return nil }
        let root = root
        return {
            root.refreshAll()
            onRefresh(root.path)
        }
    }

    /// Row actions with "Browse Folder" wired to this view's navigation, and renames and
    /// duplicates that select their result (a duplicate then goes straight into rename).
    private var rowActions: FileTreeActions {
        var rowActions = actions
        rowActions.onBrowse = navigation?.browse
        if let rename = actions.onRename {
            rowActions.onRename = { oldPath, newName, done in
                rename(oldPath, newName) { newPath in
                    done(newPath)
                    guard let newPath else { return }
                    showResult(newPath, in: (oldPath as NSString).deletingLastPathComponent)
                }
            }
        }
        if let duplicate = actions.onDuplicate {
            let canRename = actions.onRename != nil
            let renameState = renameState
            rowActions.onDuplicate = { path, done in
                duplicate(path) { copy in
                    done(copy)
                    guard let copy else { return }
                    showResult(copy, in: (path as NSString).deletingLastPathComponent) {
                        guard canRename else { return }
                        renameState.beginRename(path: copy, currentName: (copy as NSString).lastPathComponent)
                    }
                }
            }
        }
        return rowActions
    }

    // MARK: Create

    /// Show a draft row for a new file or folder in `parentPath`; nothing touches the
    /// disk until a name is entered.
    private func startCreate(in parentPath: String, isDirectory: Bool) {
        guard isDirectory ? actions.onCreateFolder != nil : actions.onCreateFile != nil else { return }
        filter.clear()
        if parentPath != root.path {
            // Revealing a (made-up) child expands every folder down to and including
            // `parentPath`, so its draft row has a place to appear.
            root.reveal((parentPath as NSString).appendingPathComponent("_"))
        }
        renameState.beginCreate(in: parentPath, isDirectory: isDirectory)
    }

    private func draftRow(_ draft: FileTreeRenameState.Draft, depth: Int, cfg: RowStyle) -> some View {
        FileTreeDraftRow(
            isDirectory: draft.isDirectory, depth: depth, style: cfg, text: $renameState.renameText,
            onCommit: { commitDraft() },
            onCancel: { renameState.cancel() }
        )
    }

    /// Create the drafted item. A trailing "/" makes a folder even from New File, and
    /// "a/b.txt" creates the missing folders on the way. A new file opens.
    private func commitDraft() {
        guard let (draft, name) = renameState.commitDraft() else { return }
        guard let target = FileTreeNaming.target(name, allowNesting: true) else {
            BooAlert.showTransient("Invalid name")
            return
        }
        let isDirectory = draft.isDirectory || target.forcesDirectory
        guard let create = isDirectory ? actions.onCreateFolder : actions.onCreateFile else { return }
        let actions = actions
        treeFocused = true
        create(draft.parentPath, target.path) { path in
            guard let path else { return }
            showResult(path, in: draft.parentPath) {
                if !isDirectory { actions.onFileClicked?(path) }
            }
        }
    }

    /// Re-list `dir` (the file watcher may not have caught up yet), then reveal and
    /// select `path`, which scrolls it into view.
    private func showResult(_ path: String, in dir: String, then: (@MainActor @Sendable () -> Void)? = nil) {
        let root = root
        let selection = selection
        root.refresh(changedDirs: [dir]) {
            root.reveal(path) { _ in
                selection.select(path)
                then?()
            }
        }
    }

    /// Scroll the cursor row into view. Rows off screen don't exist in the lazy
    /// stack, so the scroll has to go through their ForEach id.
    private func scrollToCursor(
        _ cursor: String, rows: [FlatRow], stickyFolders: Bool, proxy: ScrollViewProxy
    ) {
        // Filter rows are keyed by path relative to the root, tree rows by absolute path.
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard !filter.isActive || cursor.hasPrefix(prefix) else { return }
        let id = filter.isActive ? String(cursor.dropFirst(prefix.count)) : cursor
        // Next turn: a reveal selects the row in the same update that lists it.
        DispatchQueue.main.async {
            // A row above the view or under the pinned folders goes just below them.
            // The tree can change before this turn runs, so the index is re-checked.
            if stickyFolders, let index = rowCache.index(of: id), index < rows.count,
                FileTreeSticky.isCovered(index, in: rows, topIndex: sticky.topIndex)
            {
                scrollBelowPinned(index, rows: rows, proxy: proxy)
            } else {
                proxy.scrollTo(id)
            }
        }
    }

    /// Scroll a pinned folder's own row to just below the folders pinned above it.
    private func revealPinned(_ row: FlatRow, rows: [FlatRow], proxy: ScrollViewProxy) {
        treeFocused = true
        // A new cursor scrolls through `scrollToCursor`; only an unchanged one needs it here.
        if selection.cursor == row.node.path, let index = rowCache.index(of: row.id) {
            scrollBelowPinned(index, rows: rows, proxy: proxy)
        }
        selection.select(row.node.path)
    }

    private func scrollBelowPinned(_ index: Int, rows: [FlatRow], proxy: ScrollViewProxy) {
        let top = FileTreeSticky.topIndex(revealing: index, in: rows)
        proxy.scrollTo(rows[top].id, anchor: .top)
    }

    private func estimatedHeight(rowCount: Int, style: RowStyle) -> CGFloat {
        CGFloat(max(1, rowCount)) * (style.fontSize + 10) + 12
    }

    private func goUp() {
        guard root.path != "/" else { return }
        let parent = (root.path as NSString).deletingLastPathComponent
        if let navigation { navigation.open(parent) } else { actions.onNavigate?(parent) }
    }

    private func copyProviders(order: [String]) -> [NSItemProvider] {
        let paths = selection.ordered(in: order)
        guard !paths.isEmpty else { return [] }
        return [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress, rows: [FlatRow], order: [String]) -> KeyPress.Result {
        guard !renameState.isEditing else { return .ignored }
        let mods = press.modifiers
        let shift = mods.contains(.shift)
        let cursorRow = rows.first { $0.placeholder == nil && $0.node.path == selection.cursor }

        // ⌃⌘N new file, ⌃⇧⌘N new folder, in the cursor's folder (⌘N, ⇧⌘N and ⌥⌘N are
        // menu shortcuts). Matched by character, so it holds on any layout.
        if mods.isSuperset(of: [.command, .control]), !mods.contains(.option),
            press.key.character.lowercased() == "n"
        {
            let parent: String
            if let row = cursorRow, !filter.isActive {
                parent = row.node.isDirectory ? row.node.path : row.parentPath
            } else {
                parent = root.path
            }
            startCreate(in: parent, isDirectory: shift)
            return .handled
        }

        // ⌥-arrows navigate folders (⌘-arrows and ⌘[ ⌘] belong to menu items).
        if mods.contains(.option), let navigation {
            switch press.key {
            case .upArrow:
                goUp()
                return .handled
            case .downArrow:
                if let node = cursorRow?.node, node.isDirectory { navigation.open(node.path) }
                return .handled
            case .leftArrow:
                navigation.goBack()
                return .handled
            case .rightArrow:
                navigation.goForward()
                return .handled
            default:
                break
            }
        }

        switch press.key {
        case .upArrow:
            selection.move(by: -1, order: order, extend: shift)
            return .handled
        case .downArrow:
            selection.move(by: 1, order: order, extend: shift)
            return .handled
        case .rightArrow:
            guard let node = cursorRow?.node, node.isDirectory else { return .ignored }
            if node.isExpanded {
                selection.move(by: 1, order: order, extend: false)
            } else {
                setExpanded(node, true)
            }
            return .handled
        case .leftArrow:
            guard let row = cursorRow else { return .ignored }
            if row.node.isDirectory && row.node.isExpanded {
                setExpanded(row.node, false)
            } else if row.parentPath != root.path {
                selection.select(row.parentPath)
            }
            return .handled
        case .return:
            if filter.isActive {
                activateFirstMatch()
            } else if let node = cursorRow?.node {
                if node.isDirectory { setExpanded(node, !node.isExpanded) } else { actions.onFileClicked?(node.path) }
            }
            return .handled
        case .escape:
            if filter.isActive {
                filter.clear()
            } else {
                selection.clear()
            }
            return .handled
        case .delete where mods.contains(.command):
            let paths = selection.ordered(in: order)
            if !paths.isEmpty, actions.canRemove { pendingTrash = paths }
            return .handled
        case .delete where mods.isEmpty && !filter.isActive && navigation != nil:
            goUp()
            return .handled
        default:
            break
        }

        // F2 renames the cursor row, Finder/VS Code style.
        if press.characters == String(UnicodeScalar(NSF2FunctionKey)!), actions.onRename != nil,
            let node = cursorRow?.node
        {
            renameState.beginRename(path: node.path, currentName: node.name)
            return .handled
        }
        guard mods.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        if press.characters == "/" && AppSettings.shared.explorerShowFilterBar {
            filterFocused = true
            return .handled
        }
        return typeAheadSelect(press.characters, order: order)
    }

    /// Typing a name jumps to the first visible row starting with it; repeating a
    /// single letter cycles through rows with that initial.
    private func typeAheadSelect(_ chars: String, order: [String]) -> KeyPress.Result {
        guard let ch = chars.first, chars.count == 1, ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-"
        else { return .ignored }
        let now = Date()
        typeAhead = now.timeIntervalSince(typeAheadAt) > 1 ? String(ch) : typeAhead + String(ch)
        typeAheadAt = now
        let needle = typeAhead.lowercased()
        let names = order.map { ($0 as NSString).lastPathComponent.lowercased() }
        let repeating = needle.count > 1 && Set(needle).count == 1
        let probe = repeating ? String(needle.prefix(1)) : needle
        let start =
            (selection.cursor.flatMap { order.firstIndex(of: $0) } ?? -1) + (repeating || needle.count == 1 ? 1 : 0)
        for offset in 0..<order.count {
            let i = (max(0, start) + offset) % order.count
            if names[i].hasPrefix(probe) {
                selection.select(order[i])
                return .handled
            }
        }
        return .handled
    }

    // MARK: - Flatten

    struct FlatRow: Identifiable {
        enum Placeholder { case empty, failed }

        let node: FileTreeNode
        let depth: Int
        let parentPath: String
        /// Set for the hint row under an expanded folder that is empty or unreadable;
        /// `node` is then that folder. Placeholders never take part in selection.
        var placeholder: Placeholder? = nil
        /// Index of the parent folder's row; nil for top-level rows.
        var parentIndex: Int? = nil

        var id: String { placeholder == nil ? node.id : node.id + "\u{0}placeholder" }
    }
}
