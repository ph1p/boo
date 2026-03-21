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
}

struct FileTreeView: View {
    @ObservedObject var root: FileTreeNode
    @ObservedObject var settings = SettingsObserver()
    var actions: FileTreeActions

    var body: some View {
        let _ = settings.revision
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

            LazyVStack(alignment: .leading, spacing: 0) {
                let children = filteredChildren(of: root, showHidden: showHidden)
                ForEach(children) { node in
                    FileTreeRowView(
                        node: node, depth: 0, actions: actions,
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

    private func filteredChildren(of node: FileTreeNode, showHidden: Bool) -> [FileTreeNode] {
        guard let children = node.children else { return [] }
        if showHidden { return children }
        return children.filter { !$0.name.hasPrefix(".") }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    }
                } else {
                    actions.onFileClicked?(node.path)
                }
            }
            .contextMenu {
                if node.isDirectory {
                    Button("Open in Explorer") {
                        actions.onNavigate?(node.path)
                    }
                    Divider()
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

            if node.isExpanded, let children = node.children {
                let filtered = showHidden ? children : children.filter { !$0.name.hasPrefix(".") }
                ForEach(filtered) { child in
                    FileTreeRowView(
                        node: child, depth: depth + 1, actions: actions,
                        explorerFont: explorerFont, showIcons: showIcons,
                        showHidden: showHidden, iconSize: iconSize,
                        textColor: textColor, mutedColor: mutedColor,
                        accentColor: accentColor, hoverColor: hoverColor
                    )
                }
            }
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
