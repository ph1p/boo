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
    /// Trash one or more paths (the multi-selection); the view confirms first.
    var onMoveToTrash: (@MainActor ([String]) -> Void)?
    var onRename: (@MainActor (_ oldPath: String, _ newName: String) -> Void)?
    var onMove: (@MainActor (_ sourcePath: String, _ destinationDir: String) -> Void)?
    var onCreateFolder: (@MainActor (_ parentPath: String) -> Void)?
    var onCreateFile: (@MainActor (_ parentPath: String) -> Void)?
    var onDuplicate: (@MainActor (String) -> Void)?
    var onCopyImage: (@MainActor (String) -> Void)?
    var onReferenceInAI: (@MainActor (String) -> Void)?
    var onSetFileRoot: (@MainActor (String) -> Void)?
    var isAIAgentRunning: Bool = false

    /// Whether an AI agent holds the foreground — row actions differ, so both file-tree
    /// plugins bake it into their section generation as well as into the actions.
    @MainActor
    static func isAIAgentContext(_ context: PluginContext) -> Bool {
        ProcessIcon.category(for: context.terminal.processName) == "ai"
    }
}

// MARK: - Shared State

/// Rename state lifted out of per-row @State so it survives row rebuilds.
@MainActor final class FileTreeRenameState: ObservableObject {
    @Published var renamingPath: String?
    @Published var renameText: String = ""

    func beginRename(path: String, currentName: String) {
        renameText = currentName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.renamingPath = path
        }
    }

    func cancel() { renamingPath = nil }

    func commit(actions: FileTreeActions) {
        guard let path = renamingPath else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renamingPath = nil
        let currentName = (path as NSString).lastPathComponent
        if !newName.isEmpty && newName != currentName {
            actions.onRename?(path, newName)
        }
    }
}

/// Drag & drop state — tracks drop target position and auto-expand timer.
final class FileTreeDragState: ObservableObject {
    enum DropPosition: Equatable {
        case onFolder(String)
        case abovePath(String)
    }

    @Published var dropPosition: DropPosition?
    @Published var draggedPath: String?
    var expandTimer: DispatchWorkItem?
    var exitTimer: DispatchWorkItem?
    /// Set after performDrop — suppresses all further state changes until the
    /// next drag starts, preventing stale indicators from late delegate calls.
    private var dropped = false

    func clear() {
        dropped = true
        dropPosition = nil
        draggedPath = nil
        expandTimer?.cancel()
        expandTimer = nil
        exitTimer?.cancel()
        exitTimer = nil
    }

    func entered() {
        guard !dropped else { return }
        exitTimer?.cancel()
        exitTimer = nil
    }

    func exited() {
        guard !dropped else { return }
        expandTimer?.cancel()
        expandTimer = nil
        exitTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dropPosition = nil
            self?.draggedPath = nil
        }
        exitTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func setPosition(_ pos: DropPosition?) {
        guard !dropped else { return }
        if dropPosition != pos { dropPosition = pos }
    }

    func beginDrag(path: String) {
        dropped = false
        draggedPath = path
    }
}

// MARK: - FileTreeView

struct FileTreeView: View {
    @ObservedObject var root: FileTreeNode
    @ObservedObject var settings = SettingsObserver(topics: [.theme, .explorer, .sidebarFont, .plugins])
    @StateObject private var renameState = FileTreeRenameState()
    @StateObject private var dragState = FileTreeDragState()
    @StateObject private var selection = FileTreeSelection()
    @StateObject private var filter = FileTreeFilterModel()
    @FocusState private var treeFocused: Bool
    @FocusState private var filterFocused: Bool
    @State private var pendingTrash: [String] = []
    @State private var typeAhead = ""
    @State private var typeAheadAt = Date.distantPast
    var actions: FileTreeActions

    var body: some View {
        let _ = settings.revision
        let _ = root.treeRevision
        let theme = AppSettings.shared.theme
        let cfg = RowStyle(
            showIcons: AppSettings.shared.explorerIconsEnabled,
            fontSize: AppSettings.shared.sidebarFontSize,
            font: explorerFont,
            textColor: Color(nsColor: theme.chromeText),
            mutedColor: Color(nsColor: theme.chromeMuted),
            accentColor: Color(nsColor: theme.accentColor),
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
        let rows = filter.isActive ? [] : flattenedRows(root: root, showHidden: showHidden)
        let order = filter.isActive ? filter.matches.map { absolutePath($0.entry) } : rows.map(\.node.path)

        VStack(alignment: .leading, spacing: 0) {
            if AppSettings.shared.explorerShowFilterBar {
                FileTreeFilterBar(
                    filter: filter, focused: $filterFocused, style: cfg,
                    onCollapseAll: { root.collapseAll() },
                    onSubmit: { activateFirstMatch() },
                    onMoveIntoTree: {
                        treeFocused = true
                        selection.move(by: 1, order: order, extend: false)
                    }
                )
            }

            Group {
                if filter.isActive {
                    filterResults(cfg: cfg, git: git, order: order)
                } else {
                    tree(rows: rows, cfg: cfg, git: git, order: order)
                }
            }
            .focusable()
            .focused($treeFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { handleKey($0, rows: rows, order: order) }
            .onCopyCommand { copyProviders(order: order) }
            .onCommand(#selector(NSResponder.selectAll(_:))) { selection.selectAll(order: order) }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
        .contentShape(Rectangle())
        .contextMenu {
            Button("New File") { actions.onCreateFile?(root.path) }
            Button("New Folder") { actions.onCreateFolder?(root.path) }
            Divider()
            Button("Collapse All Folders") { root.collapseAll() }
        }
        .onDrop(
            of: [.fileURL],
            delegate: RootDropDelegate(
                dragState: dragState, actions: actions, rootPath: root.path
            )
        )
        .confirmationDialog(
            trashTitle, isPresented: trashBinding, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                actions.onMoveToTrash?(pendingTrash)
                pendingTrash = []
            }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        }
        // The plugin loads the root before handing it over; only load here when this
        // view was handed a root that has never been read (nil children), so a real
        // install doesn't re-walk the directory a second time.
        .onAppear {
            if root.children == nil { root.loadChildren() }
            filter.configure(rootPath: root.path, showHidden: showHidden)
        }
        .onChange(of: root.path) { _, path in
            selection.clear()
            filter.configure(rootPath: path, showHidden: AppSettings.shared.showHiddenFiles)
        }
        .onChange(of: showHidden) { _, hidden in filter.configure(rootPath: root.path, showHidden: hidden) }
        .onChange(of: root.contentRevision) { _, _ in filter.invalidate() }
        .onChange(of: order) { _, newOrder in selection.prune(visible: newOrder) }
    }

    // MARK: Tree

    @ViewBuilder
    private func tree(rows: [FlatRow], cfg: RowStyle, git: FileTreeGitStatus?, order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if root.path != "/" {
                ParentDirectoryButton(style: cfg) {
                    actions.onNavigate?((root.path as NSString).deletingLastPathComponent)
                }
            }

            // Multi-selection in row order, computed once for every row's context menu.
            let selectedInOrder = selection.selected.count > 1 ? selection.ordered(in: order) : []
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.node.id) { row in
                    let path = row.node.path
                    FileTreeRowView(
                        node: row.node, depth: row.depth, parentPath: row.parentPath,
                        actions: actions, renameState: renameState, dragState: dragState,
                        style: cfg, rootPath: root.path,
                        isSelected: selection.contains(path),
                        isCursor: selection.cursor == path,
                        treeFocused: treeFocused,
                        gitStatus: git?.status(for: path, isDirectory: row.node.isDirectory),
                        dimIgnored: AppSettings.shared.explorerDimIgnored,
                        menuPaths: !selectedInOrder.isEmpty && selection.contains(path) ? selectedInOrder : [path],
                        onClick: { kind in click(row.node, kind: kind, order: order) },
                        onTrash: { pendingTrash = $0 }
                    )
                }
            }
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
                    isCursor: selection.cursor == path,
                    treeFocused: treeFocused,
                    gitStatus: git?.status(for: path, isDirectory: match.entry.isDirectory),
                    onClick: { kind in
                        focusTreeUnlessOpening(kind, isDirectory: match.entry.isDirectory)
                        selection.click(path, kind: kind, order: order)
                        if kind == .plain { activate(match.entry) }
                    },
                    onReveal: { reveal(path) },
                    actions: actions
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private var explorerFont: Font {
        let name = AppSettings.shared.sidebarFontName
        let size = AppSettings.shared.sidebarFontSize
        if name.isEmpty || name == "System Default" { return .system(size: size) }
        return .custom(name, size: size)
    }

    private var trashTitle: String {
        pendingTrash.count == 1
            ? "Move \"\((pendingTrash[0] as NSString).lastPathComponent)\" to Trash?"
            : "Move \(pendingTrash.count) items to Trash?"
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
        node.isExpanded = expanded
        if expanded { node.loadChildrenAsync() }
        (node.root ?? node).treeRevision &+= 1
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
        root.reveal(path)
        selection.select(path)
        treeFocused = true
    }

    private func copyProviders(order: [String]) -> [NSItemProvider] {
        let paths = selection.ordered(in: order)
        guard !paths.isEmpty else { return [] }
        return [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress, rows: [FlatRow], order: [String]) -> KeyPress.Result {
        guard renameState.renamingPath == nil else { return .ignored }
        let mods = press.modifiers
        let shift = mods.contains(.shift)
        let cursorRow = rows.first { $0.node.path == selection.cursor }

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
            if !paths.isEmpty { pendingTrash = paths }
            return .handled
        default:
            break
        }

        // F2 renames the cursor row, Finder/VS Code style.
        if press.characters == String(UnicodeScalar(NSF2FunctionKey)!), let node = cursorRow?.node {
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

    struct FlatRow {
        let node: FileTreeNode
        let depth: Int
        let parentPath: String
    }

    private func flattenedRows(root: FileTreeNode, showHidden: Bool) -> [FlatRow] {
        var result: [FlatRow] = []
        func collect(_ node: FileTreeNode, depth: Int, parent: String) {
            guard let children = node.children else { return }
            for child in (showHidden ? children : children.filter { !$0.name.hasPrefix(".") }) {
                result.append(FlatRow(node: child, depth: depth, parentPath: parent))
                if child.isDirectory && child.isExpanded {
                    collect(child, depth: depth + 1, parent: child.path)
                }
            }
        }
        collect(root, depth: 0, parent: root.path)
        return result
    }
}

// MARK: - Row Style (shared config)

struct RowStyle {
    let showIcons: Bool
    let fontSize: CGFloat
    let font: Font
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let hoverColor: Color
    let selectionColor: Color
    let inactiveSelectionColor: Color
    let controlFill: Color
    let successColor: Color
    let warningColor: Color
    let errorColor: Color

    func color(for status: FileGitStatus) -> Color {
        switch status {
        case .modified: return warningColor
        case .added, .untracked, .renamed: return successColor
        case .deleted, .conflicted: return errorColor
        case .ignored: return mutedColor
        }
    }

    /// Name tint: git status colors, except ignored files (dimmed via opacity instead).
    func nameColor(for status: FileGitStatus?) -> Color {
        guard let status, status != .ignored else { return textColor }
        return color(for: status)
    }

    func rowBackground(selected: Bool, focused: Bool, hovered: Bool) -> Color {
        if selected { return focused ? selectionColor : inactiveSelectionColor }
        return hovered ? hoverColor : .clear
    }
}

// MARK: - Filter Bar

struct FileTreeFilterBar: View {
    @ObservedObject var filter: FileTreeFilterModel
    var focused: FocusState<Bool>.Binding
    var style: RowStyle
    var onCollapseAll: () -> Void
    var onSubmit: () -> Void
    var onMoveIntoTree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(style.mutedColor)
                TextField("Filter files", text: $filter.query)
                    .textFieldStyle(.plain)
                    .font(style.font)
                    .foregroundStyle(style.textColor)
                    .focused(focused)
                    .onSubmit(onSubmit)
                    .onKeyPress(.downArrow) {
                        onMoveIntoTree()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        filter.clear()
                        focused.wrappedValue = false
                        return .handled
                    }
                if filter.isIndexing {
                    ProgressView().controlSize(.mini)
                } else if filter.isActive {
                    Button {
                        filter.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(style.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(style.controlFill))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(focused.wrappedValue ? style.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            )

            Button(action: onCollapseAll) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(style.mutedColor)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse All Folders")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - Git Decoration

/// Trailing badge: a letter for files, a dot for folders that contain changes.
struct FileTreeGitBadge: View {
    let status: FileGitStatus?
    let isDirectory: Bool
    let style: RowStyle

    var body: some View {
        if let status, status != .ignored {
            if isDirectory {
                Circle()
                    .fill(style.color(for: status).opacity(0.8))
                    .frame(width: 5, height: 5)
            } else {
                Text(status.badge)
                    .font(.system(size: max(8, style.fontSize - 2), weight: .semibold, design: .monospaced))
                    .foregroundStyle(style.color(for: status))
            }
        }
    }
}

/// Scrolls the enclosing NSScrollView so this row stays visible while it holds the
/// keyboard cursor. The sidebar's scroll view is AppKit-owned, so `ScrollViewReader`
/// can't reach it.
private struct ScrollIntoView: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard active, !context.coordinator.wasActive else {
            context.coordinator.wasActive = active
            return
        }
        context.coordinator.wasActive = true
        DispatchQueue.main.async {
            view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -6))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var wasActive = false }
}

/// Click kind from the live modifier state — `onTapGesture` doesn't report it.
@MainActor
private func currentClickKind() -> FileTreeSelection.ClickKind {
    let flags = NSEvent.modifierFlags
    if flags.contains(.shift) { return .extend }
    if flags.contains(.command) { return .toggle }
    return .plain
}

// MARK: - Row View

struct FileTreeRowView: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    let parentPath: String
    var actions: FileTreeActions
    @ObservedObject var renameState: FileTreeRenameState
    @ObservedObject var dragState: FileTreeDragState
    var style: RowStyle
    var rootPath: String
    var isSelected: Bool
    var isCursor: Bool
    var treeFocused: Bool
    var gitStatus: FileGitStatus?
    var dimIgnored: Bool
    /// Paths the context menu acts on (the multi-selection, or just this row).
    var menuPaths: [String]
    var onClick: (FileTreeSelection.ClickKind) -> Void
    var onTrash: ([String]) -> Void
    @State private var isHovered = false

    private var isRenaming: Bool { renameState.renamingPath == node.path }
    private var isDragged: Bool { dragState.draggedPath == node.path }

    private var rowOpacity: Double {
        if isDragged { return 0.4 }
        if dimIgnored && gitStatus == .ignored { return 0.45 }
        return node.name.hasPrefix(".") ? 0.5 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            if dragState.dropPosition == .abovePath(node.path) {
                FileTreeDropLine(accentColor: style.accentColor)
                    .padding(.leading, CGFloat(depth) * 16 + 12)
            }

            rowContent
        }
        .opacity(rowOpacity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onClick(currentClickKind()) }
        .onDrag {
            dragState.beginDrag(path: node.path)
            return NSItemProvider(object: URL(fileURLWithPath: node.path) as NSURL)
        }
        .onDrop(
            of: [.fileURL],
            delegate: RowDropDelegate(
                node: node, parentPath: parentPath, dragState: dragState,
                actions: actions, rootPath: rootPath
            )
        )
        .contextMenu {
            if menuPaths.count > 1 {
                multiSelectionMenu
            } else {
                contextMenuContent
            }
        }
        .help(node.name)
        .background(ScrollIntoView(active: isCursor))
    }

    // MARK: Row Content

    private var rowContent: some View {
        let isDropTarget = dragState.dropPosition == .onFolder(node.path)
        return HStack(spacing: 5) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.mutedColor)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            if style.showIcons {
                FileTreeIcon(name: node.name, isDirectory: node.isDirectory, style: style)
            }

            if isRenaming {
                InlineRenameField(
                    text: $renameState.renameText,
                    onCommit: { renameState.commit(actions: actions) },
                    onCancel: { renameState.cancel() }
                )
            } else {
                Text(node.name)
                    .font(style.font)
                    .foregroundStyle(style.nameColor(for: gitStatus))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if node.isLoading {
                ProgressView().controlSize(.mini)
            }
            FileTreeGitBadge(status: gitStatus, isDirectory: node.isDirectory, style: style)
                .padding(.trailing, 10)
        }
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isDropTarget
                        ? style.accentColor.opacity(0.12)
                        : style.rowBackground(selected: isSelected, focused: treeFocused, hovered: isHovered)
                )
                .padding(.horizontal, 4)
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(style.accentColor, lineWidth: 1.5)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Context Menu

    private enum FileOpenCapability { case image, markdown, editor, browser, pdf, externalOnly }

    private func resolveCapability() -> FileOpenCapability {
        guard !node.isDirectory else { return .externalOnly }
        let ext = (node.name as NSString).pathExtension.lowercased()
        let filename = node.name.lowercased()
        if ContentType.imageExtensions.contains(ext) { return .image }
        if ContentType.markdownExtensions.contains(ext) { return .markdown }
        if ContentType.htmlExtensions.contains(ext) { return .browser }
        if ContentType.pdfExtensions.contains(ext) { return .pdf }

        if ContentType.isEditorFilePattern(filename: filename) { return .editor }
        return .externalOnly
    }

    @ViewBuilder
    private var multiSelectionMenu: some View {
        let count = menuPaths.count
        if actions.isAIAgentRunning {
            Button("Reference \(count) Items in AI (@)") {
                for path in menuPaths { actions.onReferenceInAI?(path) }
            }
            Divider()
        }
        Button("Paste \(count) Paths to Terminal") {
            for path in menuPaths { actions.onPastePath?(path) }
        }
        Button("Copy \(count) Paths") { actions.onCopyPath?(menuPaths.joined(separator: "\n")) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(menuPaths.map { URL(fileURLWithPath: $0) })
        }
        Divider()
        Button("Move \(count) Items to Trash", role: .destructive) { onTrash(menuPaths) }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        let cap = resolveCapability()
        if node.isDirectory && node.path == rootPath {
            Button("Set as Root") { actions.onSetFileRoot?(node.path) }
            Divider()
        }
        contextMenuOpen(cap: cap)
        contextMenuTerminal(cap: cap)
        contextMenuFinderClipboard
        contextMenuEdit
    }

    @ViewBuilder
    private func contextMenuOpen(cap: FileOpenCapability) -> some View {
        let htmlOpenInBrowser = AppSettings.shared.pluginBool(
            "file-tree-local", "htmlOpenInBrowser", default: false)
        let pdfOpenInBrowser = AppSettings.shared.pluginBool(
            "file-tree-local", "pdfOpenInBrowser", default: true)

        if actions.isAIAgentRunning {
            Button("Reference in AI (@)") { actions.onReferenceInAI?(node.path) }
            Divider()
        }

        if node.isDirectory {
            if !actions.isAIAgentRunning {
                Button("cd into") { actions.onNavigate?(node.path) }
            }
            Button("Open Terminal Tab") { actions.onOpenInTab?(node.path) }
            Button("Open Terminal Pane") { actions.onOpenInPane?(node.path) }
            if node.isExpanded {
                Button("Collapse Subfolders") { node.collapseAll() }
            }
        } else {
            Button("Open") { actions.onFileClicked?(node.path) }
            if cap != .externalOnly {
                Button("Open in New Tab") { actions.onOpenFileInTab?(node.path) }
                Button("Open in New Pane") { actions.onOpenFileInPane?(node.path) }
            }
            Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: node.path)) }
            if (cap == .browser && !htmlOpenInBrowser) || (cap == .pdf && !pdfOpenInBrowser) {
                Button("Open in Browser") { actions.onOpenFileInBrowser?(node.path) }
            }
            if cap == .image {
                Button("Copy Image") { actions.onCopyImage?(node.path) }
            }
        }
    }

    @ViewBuilder
    private func contextMenuTerminal(cap: FileOpenCapability) -> some View {
        Divider()
        Button("Paste Path to Terminal") { actions.onPastePath?(node.path) }
        if !node.isDirectory && cap != .image {
            Button("cat in Terminal") { actions.onRunCommand?("cat \(shellEscape(node.path))\r") }
        }
    }

    @ViewBuilder
    private var contextMenuFinderClipboard: some View {
        Divider()
        Button("Reveal in Finder") { actions.onRevealInFinder?(node.path) }
        Button("Copy Path") { actions.onCopyPath?(node.path) }
        Button("Copy Relative Path") {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            actions.onCopyPath?(node.path.hasPrefix(prefix) ? String(node.path.dropFirst(prefix.count)) : node.path)
        }
    }

    @ViewBuilder
    private var contextMenuEdit: some View {
        Divider()
        if node.isDirectory {
            Button("New File") { actions.onCreateFile?(node.path) }
            Button("New Folder") { actions.onCreateFolder?(node.path) }
        } else {
            Button("Duplicate") { actions.onDuplicate?(node.path) }
        }
        Button("Rename") { renameState.beginRename(path: node.path, currentName: node.name) }
        Button("Move to Trash", role: .destructive) { onTrash([node.path]) }
    }
}

// MARK: - Filter Match Row

struct FileTreeMatchRowView: View {
    let match: FileTreeFilterMatch
    let absolutePath: String
    var style: RowStyle
    var isSelected: Bool
    var isCursor: Bool
    var treeFocused: Bool
    var gitStatus: FileGitStatus?
    var onClick: (FileTreeSelection.ClickKind) -> Void
    var onReveal: () -> Void
    var actions: FileTreeActions
    @State private var isHovered = false

    private var path: String { match.entry.relativePath }

    var body: some View {
        HStack(spacing: 5) {
            if style.showIcons {
                FileTreeIcon(name: match.entry.name, isDirectory: match.entry.isDirectory, style: style)
            }
            highlightedName
                .font(style.font)
                .lineLimit(1)
                .layoutPriority(1)
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                Text(parent)
                    .font(.system(size: max(9, style.fontSize - 2)))
                    .foregroundStyle(style.mutedColor)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            FileTreeGitBadge(status: gitStatus, isDirectory: match.entry.isDirectory, style: style)
                .padding(.trailing, 10)
        }
        .padding(.leading, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(style.rowBackground(selected: isSelected, focused: treeFocused, hovered: isHovered))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onClick(currentClickKind()) }
        .help(path)
        .background(ScrollIntoView(active: isCursor))
        .contextMenu {
            Button("Reveal in Tree") { onReveal() }
            if !match.entry.isDirectory {
                Button("Open") { onClick(.plain) }
            }
            Divider()
            Button("Paste Path to Terminal") { actions.onPastePath?(absolutePath) }
            Button("Copy Path") { actions.onCopyPath?(absolutePath) }
            Button("Reveal in Finder") { actions.onRevealInFinder?(absolutePath) }
        }
    }

    /// Name with the fuzzy-matched characters emphasized.
    private var highlightedName: Text {
        var name = AttributedString(match.entry.name)
        name.foregroundColor = style.nameColor(for: gitStatus)
        let indices = Array(name.characters.indices)
        for i in match.nameHighlights where i < indices.count {
            let range = indices[i]..<name.characters.index(after: indices[i])
            name[range].foregroundColor = style.accentColor
            name[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(name)
    }
}

// MARK: - Icon

struct FileTreeIcon: View {
    let name: String
    let isDirectory: Bool
    var style: RowStyle

    var body: some View {
        Image(systemName: isDirectory ? folderIcon(for: name) : fileIcon(for: name))
            .font(.system(size: style.fontSize))
            .frame(width: 16, height: 16)
            .foregroundStyle(isDirectory ? style.accentColor.opacity(0.8) : style.mutedColor)
    }
}

// MARK: - Drop Line

struct FileTreeDropLine: View {
    var accentColor: Color
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(accentColor).frame(width: 6, height: 6)
            Rectangle().fill(accentColor).frame(height: 1.5)
        }
        .frame(height: 2)
        .padding(.trailing, 8)
    }
}

// MARK: - Drop Delegates

private let rowHeight: CGFloat = 22

/// Move dropped file URLs into the target directory.
private func executeDrop(info: DropInfo, target: String, dragState: FileTreeDragState, actions: FileTreeActions) {
    dragState.clear()
    for provider in info.itemProviders(for: [.fileURL]) {
        provider.loadObject(ofClass: NSURL.self) { item, _ in
            guard let url = item as? URL else { return }
            DispatchQueue.main.async { actions.onMove?(url.path, target) }
        }
    }
}

/// Returns false if `path` is the dragged item or a descendant of it.
private func isValidDropTarget(_ path: String, dragState: FileTreeDragState) -> Bool {
    guard dragState.draggedPath != path else { return false }
    if let d = dragState.draggedPath, path.hasPrefix(d + "/") { return false }
    return true
}

/// Per-row drop delegate. Folders: top quarter = line above, rest = into folder.
/// Files: always line above (into parent dir).
struct RowDropDelegate: DropDelegate {
    let node: FileTreeNode
    let parentPath: String
    let dragState: FileTreeDragState
    let actions: FileTreeActions
    let rootPath: String

    func validateDrop(info: DropInfo) -> Bool {
        isValidDropTarget(node.path, dragState: dragState)
    }

    func dropEntered(info: DropInfo) {
        dragState.entered()
        update(info)
        if node.isDirectory && !node.isExpanded {
            dragState.expandTimer?.cancel()
            let path = node.path
            let timer = DispatchWorkItem { [weak node] in
                guard let node, dragState.dropPosition == .onFolder(path) else { return }
                node.isExpanded = true
                node.loadChildren()
                (node.root ?? node).treeRevision &+= 1
            }
            dragState.expandTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timer)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { dragState.exited() }

    func performDrop(info: DropInfo) -> Bool {
        let target: String
        switch dragState.dropPosition {
        case .onFolder(let p): target = p
        case .abovePath: target = parentPath
        case .none: target = rootPath
        }
        executeDrop(info: info, target: target, dragState: dragState, actions: actions)
        return true
    }

    private func update(_ info: DropInfo) {
        guard isValidDropTarget(node.path, dragState: dragState) else {
            dragState.setPosition(nil)
            return
        }
        let fraction = max(0, min(1, info.location.y / rowHeight))
        if node.isDirectory && fraction >= 0.25 {
            dragState.setPosition(.onFolder(node.path))
        } else {
            dragState.setPosition(.abovePath(node.path))
        }
    }
}

/// Root-level drop delegate for the background / empty space — drops into root dir.
struct RootDropDelegate: DropDelegate {
    let dragState: FileTreeDragState
    let actions: FileTreeActions
    let rootPath: String

    func dropEntered(info: DropInfo) { dragState.entered() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { dragState.exited() }

    func performDrop(info: DropInfo) -> Bool {
        executeDrop(info: info, target: rootPath, dragState: dragState, actions: actions)
        return true
    }
}

// MARK: - Inline Rename Field

struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.isEditable = true
        field.focusRingType = .exterior
        field.stringValue = text
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        context.coordinator.field = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            let name = field.stringValue
            // Select filename stem (without extension)
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                let len = name.distance(from: name.startIndex, to: dot)
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: len)
            } else {
                field.selectText(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: InlineRenameField
        weak var field: NSTextField?
        var activated = false

        init(_ parent: InlineRenameField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { activated = true }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard activated, let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Parent Directory Button

struct ParentDirectoryButton: View {
    var mutedColor: Color
    var hoverColor: Color
    var explorerFont: Font
    var action: () -> Void
    @State private var isHovered = false

    init(style: RowStyle, action: @escaping () -> Void) {
        self.mutedColor = style.mutedColor
        self.hoverColor = style.hoverColor
        self.explorerFont = style.font
        self.action = action
    }

    init(mutedColor: Color, hoverColor: Color, explorerFont: Font, action: @escaping () -> Void) {
        self.mutedColor = mutedColor
        self.hoverColor = hoverColor
        self.explorerFont = explorerFont
        self.action = action
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 9))
                .foregroundStyle(mutedColor)
                .frame(width: 10)
            Text("..").font(explorerFont).foregroundStyle(mutedColor).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.vertical, 3)
        .padding(.top, 0)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? hoverColor : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
    }
}
