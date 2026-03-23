import SwiftUI

struct FileTreeActions {
    var onFileClicked: ((String) -> Void)?
    var onOpenInTab: ((String) -> Void)?
    var onOpenInPane: ((String) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onRevealInFinder: ((String) -> Void)?
    var onRunCommand: ((String) -> Void)?  // send raw text to PTY (e.g. "cat /path\r")
    var onNavigate: ((String) -> Void)?  // navigate file tree to a directory (no terminal command)
    var onMoveToTrash: ((String) -> Void)?
    var onReferenceInAI: ((String) -> Void)?  // send @path to AI agent in terminal
    var isAIAgentRunning: Bool = false
}

struct FileTreeView: View {
    @ObservedObject var root: FileTreeNode
    @ObservedObject var settings = SettingsObserver(topics: [.theme, .explorer])
    var actions: FileTreeActions

    var body: some View {
        let _ = settings.revision
        let _ = root.treeRevision  // trigger re-flatten on expand/collapse/load
        let showIcons = AppSettings.shared.explorerIconsEnabled
        let showHidden = AppSettings.shared.showHiddenFiles
        let theme = AppSettings.shared.theme
        let fontSize = AppSettings.shared.explorerFontSize
        let fontName = AppSettings.shared.explorerFontName
        let mutedColor = Color(nsColor: theme.chromeMuted)
        let textColor = Color(nsColor: theme.chromeText)
        let accentColor = Color(nsColor: theme.accentColor)
        let sidebarBgColor = Color(nsColor: theme.sidebarBg)
        let hoverColor = Color(nsColor: theme.chromeMuted).opacity(0.15)

        let explorerFont: Font = {
            if fontName.isEmpty || fontName == "System Default" {
                return .system(size: fontSize)
            }
            return .custom(fontName, size: fontSize)
        }()

        VStack(alignment: .leading, spacing: 0) {
            if root.path != "/" {
                ParentDirectoryButton(
                    mutedColor: mutedColor, hoverColor: hoverColor, explorerFont: explorerFont
                ) {
                    let parent = (root.path as NSString).deletingLastPathComponent
                    actions.onNavigate?(parent)
                }
            }

            // Flat LazyVStack so all rows participate in lazy loading.
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = flattenedRows(root: root, showHidden: showHidden)
                ForEach(rows, id: \.node.id) { row in
                    FileTreeRowView(
                        node: row.node, depth: row.depth, actions: actions,
                        explorerFont: explorerFont, showIcons: showIcons,
                        showHidden: showHidden, iconSize: fontSize,
                        textColor: textColor, mutedColor: mutedColor,
                        accentColor: accentColor, hoverColor: hoverColor
                    )
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .background(sidebarBgColor)
        .onAppear {
            root.loadChildren()
        }
    }

    private struct FlatRow {
        let node: FileTreeNode
        let depth: Int
    }

    /// Build a flat list of visible rows so `LazyVStack` can virtualise them.
    private func flattenedRows(root: FileTreeNode, showHidden: Bool) -> [FlatRow] {
        var result: [FlatRow] = []
        func collect(_ node: FileTreeNode, depth: Int) {
            guard let children = node.children else { return }
            let filtered = showHidden ? children : children.filter { !$0.name.hasPrefix(".") }
            for child in filtered {
                result.append(FlatRow(node: child, depth: depth))
                if child.isDirectory && child.isExpanded {
                    collect(child, depth: depth + 1)
                }
            }
        }
        collect(root, depth: 0)
        return result
    }
}

struct FileTreeRowView: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    var actions: FileTreeActions
    var explorerFont: Font
    var showIcons: Bool
    var showHidden: Bool
    var iconSize: CGFloat
    var textColor: Color
    var mutedColor: Color
    var accentColor: Color
    var hoverColor: Color
    @State private var isHovered = false
    @State private var showTrashConfirmation = false

    // Children are rendered by the flat LazyVStack in FileTreeView —
    // this view only renders a single row.
    var body: some View {
        HStack(spacing: 5) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(mutedColor)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            if showIcons {
                Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                    .font(.system(size: iconSize))
                    .frame(width: 16, height: 16)
                    .foregroundColor(node.isDirectory ? accentColor.opacity(0.8) : mutedColor)
            }

            Text(node.name)
                .font(explorerFont)
                .foregroundColor(textColor)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? hoverColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .opacity(node.name.hasPrefix(".") ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if node.isDirectory {
                withAnimation(.easeInOut(duration: 0.15)) {
                    node.isExpanded.toggle()
                    if node.isExpanded {
                        node.loadChildren()
                    }
                    // Notify root so the flat list is recalculated.
                    let treeRoot = node.root ?? node
                    treeRoot.treeRevision &+= 1
                }
            } else {
                actions.onFileClicked?(node.path)
            }
        }
        .contextMenu {
            if actions.isAIAgentRunning {
                Button("Reference in AI (@)") {
                    actions.onReferenceInAI?(node.path)
                }
                Divider()
            }

            if node.isDirectory {
                if !actions.isAIAgentRunning {
                    Button("cd into") {
                        actions.onNavigate?(node.path)
                    }
                    Divider()
                }
                Button("Open in New Tab") {
                    actions.onOpenInTab?(node.path)
                }
                Button("Open in New Pane") {
                    actions.onOpenInPane?(node.path)
                }
                Divider()
            } else {
                Button("cat") {
                    actions.onRunCommand?("cat \(shellEscape(node.path))\r")
                }
                Button("Open with Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
                }
                Divider()
            }

            Button("Copy Path") {
                actions.onCopyPath?(node.path)
            }

            Button("Paste Path to Terminal") {
                actions.onFileClicked?(node.path)
            }

            Divider()

            Button("Reveal in Finder") {
                actions.onRevealInFinder?(node.path)
            }

            Divider()

            Button("Move to Trash", role: .destructive) {
                showTrashConfirmation = true
            }
        }
        .confirmationDialog(
            "Move \"\(node.name)\" to Trash?",
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                actions.onMoveToTrash?(node.path)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

}

/// Compact "go up" row shown at the top of the file tree when not at root.
struct ParentDirectoryButton: View {
    var mutedColor: Color
    var hoverColor: Color
    var explorerFont: Font
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 9))
                .foregroundColor(mutedColor)
                .frame(width: 10)

            Text("..")
                .font(explorerFont)
                .foregroundColor(mutedColor)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, 12)
        .padding(.vertical, 3)
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? hoverColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { action() }
    }

}
