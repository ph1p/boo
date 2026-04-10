import SwiftUI
import UniformTypeIdentifiers

// MARK: - Actions

struct FileTreeActions {
    var onFileClicked: ((String) -> Void)?
    var onPastePath: ((String) -> Void)?
    var onOpenInTab: ((String) -> Void)?
    var onOpenInPane: ((String) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onRevealInFinder: ((String) -> Void)?
    var onRunCommand: ((String) -> Void)?
    var onNavigate: ((String) -> Void)?
    var onMoveToTrash: ((String) -> Void)?
    var onRename: ((_ oldPath: String, _ newName: String) -> Void)?
    var onMove: ((_ sourcePath: String, _ destinationDir: String) -> Void)?
    var onCreateFolder: ((_ parentPath: String) -> Void)?
    var onCopyImage: ((String) -> Void)?
    var onReferenceInAI: ((String) -> Void)?
    var isAIAgentRunning: Bool = false
}

// MARK: - Shared State

/// Rename state lifted out of per-row @State so it survives row rebuilds.
final class FileTreeRenameState: ObservableObject {
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
    @ObservedObject var settings = SettingsObserver(topics: [.theme, .explorer, .sidebarFont])
    @StateObject private var renameState = FileTreeRenameState()
    @StateObject private var dragState = FileTreeDragState()
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
            hoverColor: Color(nsColor: theme.chromeMuted).opacity(0.15)
        )
        let showHidden = AppSettings.shared.showHiddenFiles
        let rows = flattenedRows(root: root, showHidden: showHidden)

        VStack(alignment: .leading, spacing: 0) {
            if root.path != "/" {
                ParentDirectoryButton(style: cfg) {
                    actions.onNavigate?((root.path as NSString).deletingLastPathComponent)
                }
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.node.id) { row in
                    FileTreeRowView(
                        node: row.node, depth: row.depth, parentPath: row.parentPath,
                        actions: actions, renameState: renameState, dragState: dragState,
                        style: cfg, rootPath: root.path, showHidden: showHidden
                    )
                }
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Folder") { actions.onCreateFolder?(root.path) }
        }
        .onDrop(
            of: [.fileURL],
            delegate: RootDropDelegate(
                dragState: dragState, actions: actions, rootPath: root.path
            )
        )
        .onAppear { root.loadChildren() }
    }

    private var explorerFont: Font {
        let name = AppSettings.shared.sidebarFontName
        let size = AppSettings.shared.sidebarFontSize
        if name.isEmpty || name == "System Default" { return .system(size: size) }
        return .custom(name, size: size)
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
    var showHidden: Bool
    @State private var isHovered = false
    @State private var showTrashConfirm = false

    private var isRenaming: Bool { renameState.renamingPath == node.path }
    private var isDragged: Bool { dragState.draggedPath == node.path }

    var body: some View {
        VStack(spacing: 0) {
            if dragState.dropPosition == .abovePath(node.path) {
                FileTreeDropLine(accentColor: style.accentColor)
                    .padding(.leading, CGFloat(depth) * 16 + 12)
            }

            rowContent
        }
        .opacity(isDragged ? 0.4 : (node.name.hasPrefix(".") ? 0.5 : 1.0))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { handleTap() }
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
        .contextMenu { contextMenuContent }
        .confirmationDialog(
            "Move \"\(node.name)\" to Trash?",
            isPresented: $showTrashConfirm, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { actions.onMoveToTrash?(node.path) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Row Content

    private var rowContent: some View {
        let isDropTarget = dragState.dropPosition == .onFolder(node.path)
        return HStack(spacing: 5) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(style.mutedColor)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            if style.showIcons {
                Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                    .font(.system(size: style.fontSize))
                    .frame(width: 16, height: 16)
                    .foregroundColor(node.isDirectory ? style.accentColor.opacity(0.8) : style.mutedColor)
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
                    .foregroundColor(style.textColor)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTarget ? style.accentColor.opacity(0.12) : (isHovered ? style.hoverColor : .clear))
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

    // MARK: Tap

    private func handleTap() {
        guard !isRenaming else { return }
        if node.isDirectory {
            node.isExpanded.toggle()
            if node.isExpanded { node.loadChildren() }
            (node.root ?? node).treeRevision &+= 1
        } else {
            actions.onFileClicked?(node.path)
        }
    }

    // MARK: Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // AI
        if actions.isAIAgentRunning {
            Button("Reference in AI (@)") { actions.onReferenceInAI?(node.path) }
            Divider()
        }

        // Terminal
        if node.isDirectory {
            if !actions.isAIAgentRunning {
                Button("cd into") { actions.onNavigate?(node.path) }
            }
        } else {
            Button("Open in Editor") { actions.onFileClicked?(node.path) }
            let ext = (node.name as NSString).pathExtension
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
            if isImage {
                Button("Copy Image") { actions.onCopyImage?(node.path) }
            } else {
                Button("cat") { actions.onRunCommand?("cat \(shellEscape(node.path))\r") }
            }
        }
        Button("Paste Path to Terminal") { actions.onPastePath?(node.path) }
        Divider()

        // OS
        if node.isDirectory {
            Button("Open in New Tab") { actions.onOpenInTab?(node.path) }
            Button("Open in New Pane") { actions.onOpenInPane?(node.path) }
        } else {
            Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: node.path)) }
        }
        Button("Reveal in Finder") { actions.onRevealInFinder?(node.path) }
        Button("Copy Path") { actions.onCopyPath?(node.path) }
        Divider()

        // Edit
        if node.isDirectory {
            Button("New Folder") { actions.onCreateFolder?(node.path) }
        }
        Button("Rename") { renameState.beginRename(path: node.path, currentName: node.name) }
        Button("Move to Trash", role: .destructive) { showTrashConfirm = true }
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
                .foregroundColor(mutedColor)
                .frame(width: 10)
            Text("..").font(explorerFont).foregroundColor(mutedColor).lineLimit(1)
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
