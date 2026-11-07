import SwiftUI
import UniformTypeIdentifiers

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

    /// Leading inset of a row's chevron at `depth`.
    static func indent(depth: Int) -> CGFloat { CGFloat(depth) * 16 + 12 }

    func rowBackground(selected: Bool, focused: Bool, hovered: Bool) -> Color {
        if selected { return focused ? selectionColor : inactiveSelectionColor }
        return hovered ? hoverColor : .clear
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

/// Click kind from the live modifier state — `onTapGesture` doesn't report it.
@MainActor
private func currentClickKind() -> FileTreeSelection.ClickKind {
    let flags = NSEvent.modifierFlags
    if flags.contains(.shift) { return .extend }
    if flags.contains(.command) { return .toggle }
    return .plain
}

// MARK: - Row Cache

/// Flattened rows and their path order, rebuilt only when the tree's shape changes.
/// Selection, focus, hover and drag updates re-run `FileTreeView.body` but leave the
/// tree alone, so they reuse the last flattening instead of walking every node.
/// Every structural change (listing, expand, collapse) bumps the root's `treeRevision`.
final class FileTreeRowCache {
    private struct Key: Equatable {
        let root: ObjectIdentifier
        let revision: Int
        let showHidden: Bool
    }

    private var key: Key?
    private var cached: (rows: [FileTreeView.FlatRow], order: [String]) = ([], [])
    private var indexByID: [String: Int] = [:]

    /// Position of a row id in the last rows built.
    func index(of id: String) -> Int? { indexByID[id] }

    func rows(for root: FileTreeNode, showHidden: Bool) -> (rows: [FileTreeView.FlatRow], order: [String]) {
        let key = Key(root: ObjectIdentifier(root), revision: root.treeRevision, showHidden: showHidden)
        guard key != self.key else { return cached }
        var rows: [FileTreeView.FlatRow] = []
        /// Appends the visible children of `node`; returns how many it appended.
        @discardableResult
        func collect(_ node: FileTreeNode, depth: Int, parent: String, parentIndex: Int?) -> Int {
            guard let children = node.children else { return 0 }
            let visible = showHidden ? children : children.filter { !$0.name.hasPrefix(".") }
            for child in visible {
                let index = rows.count
                rows.append(.init(node: child, depth: depth, parentPath: parent, parentIndex: parentIndex))
                guard child.isDirectory && child.isExpanded else { continue }
                let added = collect(child, depth: depth + 1, parent: child.path, parentIndex: index)
                let placeholder: FileTreeView.FlatRow.Placeholder? =
                    child.loadFailed ? .failed : (added == 0 && child.children != nil ? .empty : nil)
                if let placeholder {
                    rows.append(
                        .init(
                            node: child, depth: depth + 1, parentPath: child.path, placeholder: placeholder,
                            parentIndex: index))
                }
            }
            return visible.count
        }
        collect(root, depth: 0, parent: root.path, parentIndex: nil)
        self.key = key
        cached = (rows, rows.compactMap { $0.placeholder == nil ? $0.node.path : nil })
        indexByID = [:]
        indexByID.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() { indexByID[row.id] = index }
        return cached
    }
}

// MARK: - Row View

struct FileTreeRowView: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    let parentPath: String
    var actions: FileTreeActions
    @ObservedObject var renameState: FileTreeRenameState
    /// Not observed: rows get their drag state as values below, so a moving drop
    /// target re-renders only the rows it enters and leaves.
    let dragState: FileTreeDragState
    var dropLineAbove: Bool
    var isDropTarget: Bool
    var isDragged: Bool
    var style: RowStyle
    var rootPath: String
    var isSelected: Bool
    var treeFocused: Bool
    var gitStatus: FileGitStatus?
    var dimIgnored: Bool
    /// Paths the context menu acts on (the multi-selection, or just this row).
    var menuPaths: [String]
    var onClick: (FileTreeSelection.ClickKind) -> Void
    var onTrash: ([String]) -> Void
    @State private var isHovered = false
    /// Size/date line for the tooltip, fetched once after the pointer rests on the row.
    @State private var info: String?
    @State private var infoRequested = false

    private var isRenaming: Bool { renameState.renamingPath == node.path }

    private var rowOpacity: Double {
        if isDragged { return 0.4 }
        if dimIgnored && gitStatus == .ignored { return 0.45 }
        return node.name.hasPrefix(".") ? 0.5 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            if dropLineAbove {
                FileTreeDropLine(accentColor: style.accentColor)
                    .padding(.leading, RowStyle.indent(depth: depth))
            }

            rowContent
        }
        .opacity(rowOpacity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { requestInfo() }
        }
        .onTapGesture { onClick(currentClickKind()) }
        .onDrag {
            dragState.beginDrag(path: node.path)
            // A remote path is no file on this Mac: drag it as text, so it can still
            // move inside the tree or drop into a terminal as a path.
            return node.source.isLocal
                ? NSItemProvider(object: URL(fileURLWithPath: node.path) as NSURL)
                : NSItemProvider(object: node.path as NSString)
        }
        .onDrop(
            of: fileTreeDropTypes,
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
        .help(info.map { "\(node.name)\n\($0)" } ?? node.name)
    }

    private func requestInfo() {
        guard !infoRequested, let fetch = actions.onFetchInfo else { return }
        let path = node.path
        Task { @MainActor in
            // Only rows the pointer rests on: sweeping across the tree must not fire a
            // remote round-trip per row.
            try? await Task.sleep(for: .milliseconds(400))
            guard isHovered, !infoRequested else { return }
            infoRequested = true
            info = await fetch(path)
        }
    }

    // MARK: Row Content

    private var rowContent: some View {
        HStack(spacing: 5) {
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
        .padding(.leading, RowStyle.indent(depth: depth))
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
        if actions.onRevealInFinder != nil {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(menuPaths.map { URL(fileURLWithPath: $0) })
            }
        }
        if let onDownload = actions.onDownload {
            Button("Download \(count) Items") { onDownload(menuPaths) }
        }
        if actions.canRemove {
            Divider()
            Button(
                actions.removesToTrash ? "Move \(count) Items to Trash" : "Delete \(count) Items",
                role: .destructive
            ) { onTrash(menuPaths) }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        let cap = resolveCapability()
        if node.isDirectory && node.path == rootPath, let onSetFileRoot = actions.onSetFileRoot {
            Button("Set as Root") { onSetFileRoot(node.path) }
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
            if let onBrowse = actions.onBrowse {
                Button("Browse Folder") { onBrowse(node.path) }
            }
            if !actions.isAIAgentRunning {
                Button("cd into") { actions.onNavigate?(node.path) }
            }
            if let onOpenInTab = actions.onOpenInTab {
                Button("Open Terminal Tab") { onOpenInTab(node.path) }
            }
            if let onOpenInPane = actions.onOpenInPane {
                Button("Open Terminal Pane") { onOpenInPane(node.path) }
            }
            if node.isExpanded {
                Button("Collapse Subfolders") { node.collapseAll() }
            }
        } else {
            Button("Open") { actions.onFileClicked?(node.path) }
            if cap != .externalOnly {
                if let onOpenFileInTab = actions.onOpenFileInTab {
                    Button("Open in New Tab") { onOpenFileInTab(node.path) }
                }
                if let onOpenFileInPane = actions.onOpenFileInPane {
                    Button("Open in New Pane") { onOpenFileInPane(node.path) }
                }
            }
            if let onOpenExternally = actions.onOpenExternally {
                Button("Open with Default App") { onOpenExternally(node.path) }
            }
            if (cap == .browser && !htmlOpenInBrowser) || (cap == .pdf && !pdfOpenInBrowser),
                let onOpenFileInBrowser = actions.onOpenFileInBrowser
            {
                Button("Open in Browser") { onOpenFileInBrowser(node.path) }
            }
            if cap == .image, let onCopyImage = actions.onCopyImage {
                Button("Copy Image") { onCopyImage(node.path) }
            }
        }
        if let onDownload = actions.onDownload {
            Button("Download") { onDownload([node.path]) }
        }
    }

    @ViewBuilder
    private func contextMenuTerminal(cap: FileOpenCapability) -> some View {
        Divider()
        Button("Paste Path to Terminal") { actions.onPastePath?(node.path) }
        if !node.isDirectory && cap != .image {
            Button("cat in Terminal") { actions.onRunCommand?("cat \(RemoteExplorer.shellEscPath(node.path))\r") }
        }
    }

    @ViewBuilder
    private var contextMenuFinderClipboard: some View {
        Divider()
        if let onRevealInFinder = actions.onRevealInFinder {
            Button("Reveal in Finder") { onRevealInFinder(node.path) }
        }
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
            if let onCreateFile = actions.onCreateFile {
                Button("New File") { onCreateFile(node.path) }
            }
            if let onCreateFolder = actions.onCreateFolder {
                Button("New Folder") { onCreateFolder(node.path) }
            }
        } else if let onDuplicate = actions.onDuplicate {
            Button("Duplicate") { onDuplicate(node.path) }
        }
        if actions.onRename != nil {
            Button("Rename") { renameState.beginRename(path: node.path, currentName: node.name) }
        }
        if actions.canRemove {
            Button(actions.removesToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                onTrash([node.path])
            }
        }
    }
}

// MARK: - Filter Match Row

struct FileTreeMatchRowView: View {
    let match: FileTreeFilterMatch
    let absolutePath: String
    var style: RowStyle
    var isSelected: Bool
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
        .contextMenu {
            Button("Reveal in Tree") { onReveal() }
            if !match.entry.isDirectory {
                Button("Open") { onClick(.plain) }
            } else if let onBrowse = actions.onBrowse {
                Button("Browse Folder") { onBrowse(absolutePath) }
            }
            Divider()
            Button("Paste Path to Terminal") { actions.onPastePath?(absolutePath) }
            Button("Copy Path") { actions.onCopyPath?(absolutePath) }
            if let onRevealInFinder = actions.onRevealInFinder {
                Button("Reveal in Finder") { onRevealInFinder(absolutePath) }
            }
            if !match.entry.isDirectory, let onDownload = actions.onDownload {
                Button("Download") { onDownload([absolutePath]) }
            }
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

// MARK: - Placeholder Row

/// Muted hint under an expanded folder (or at the root) that has nothing to show.
struct FileTreePlaceholderRow: View {
    let text: String
    let depth: Int
    var style: RowStyle
    var onRetry: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(style.font)
                .italic()
                .foregroundStyle(style.mutedColor)
                .lineLimit(1)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.link)
                    .font(style.font)
            }
            Spacer(minLength: 0)
        }
        // Lines up with the names of sibling rows (chevron 10 + spacing 5).
        .padding(.leading, RowStyle.indent(depth: depth) + 15)
        .padding(.vertical, 3)
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
