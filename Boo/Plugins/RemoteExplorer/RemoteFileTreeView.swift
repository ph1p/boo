import SwiftUI

/// Shown while waiting for the remote session to authenticate/connect.
struct RemoteConnectingView: View {
    let session: RemoteSessionType

    var body: some View {
        let theme = AppSettings.shared.theme

        VStack(spacing: 12) {
            Spacer()

            Image(systemName: session.icon)
                .font(.system(size: 28))
                .foregroundColor(Color(nsColor: theme.accentColor).opacity(0.6))

            Text("Connecting to")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: theme.chromeMuted))

            Text(session.displayName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: theme.chromeText))

            ProgressView()
                .scaleEffect(0.7)
                .padding(.top, 4)

            Text(session.connectingHint)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
    }

}

/// Shown when the file explorer could not connect to the remote session.
struct RemoteConnectionFailedView: View {
    let session: RemoteSessionType
    var onRetry: (() -> Void)?
    @State private var isRetrying = false

    var body: some View {
        let theme = AppSettings.shared.theme

        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "xmark.circle")
                .font(.system(size: 28))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))

            Text("Could not connect to")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: theme.chromeMuted))

            Text(session.displayName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: theme.chromeText))

            Text("File explorer requires key-based\nSSH auth or SSH agent.")
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if isRetrying {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("Retry") {
                    isRetrying = true
                    if session.isSSHBased {
                        SSHControlManager.shared.ensureConnection(alias: session.sshConnectionTarget) { [self] _ in
                            self.isRetrying = false
                            self.onRetry?()
                        }
                    } else {
                        isRetrying = false
                        onRetry?()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
    }

}

struct RemoteFileTreeView: View {
    @ObservedObject var root: RemoteFileTreeNode
    @ObservedObject var settings = SettingsObserver(topics: [.theme, .explorer, .sidebarFont])
    var actions: FileTreeActions
    let host: String  // display name

    var body: some View {
        let _ = settings.revision
        let _ = root.treeRevision  // trigger re-flatten on expand/collapse/load
        let theme = AppSettings.shared.theme
        let showIcons = AppSettings.shared.explorerIconsEnabled
        let showHidden = AppSettings.shared.showHiddenFiles
        let fontSize = AppSettings.shared.sidebarFontSize
        let fontName = AppSettings.shared.sidebarFontName
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

        Group {
            if root.children == nil && root.isLoading {
                RemoteConnectingView(session: root.session)
            } else if root.loadFailed {
                RemoteConnectionFailedView(session: root.session) {
                    root.resetForRetry()
                    root.loadChildren()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if root.remotePath != "/" {
                        ParentDirectoryButton(
                            mutedColor: mutedColor, hoverColor: hoverColor, explorerFont: explorerFont
                        ) {
                            let parent = (root.remotePath as NSString).deletingLastPathComponent
                            actions.onNavigate?(parent.isEmpty ? "/" : parent)
                        }
                    }

                    // Use a flat LazyVStack so all rows — including nested
                    // children — participate in lazy loading.  The previous
                    // recursive VStack rendered every expanded child eagerly,
                    // which caused scroll/performance issues in large dirs.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let rows = flattenedRows(root: root, showHidden: showHidden)
                        ForEach(rows, id: \.node.id) { row in
                            RemoteFileTreeRowView(
                                node: row.node, depth: row.depth, actions: actions,
                                explorerFont: explorerFont, showIcons: showIcons,
                                showHidden: showHidden, iconSize: fontSize,
                                textColor: textColor, mutedColor: mutedColor,
                                accentColor: accentColor, hoverColor: hoverColor
                            )
                        }
                    }
                    .padding(.bottom, 20)
                }
                .background(sidebarBgColor)
            }
        }
        .onAppear {
            root.loadChildren()
        }
    }

    private struct FlatRow {
        let node: RemoteFileTreeNode
        let depth: Int
    }

    /// Build a flat list of visible rows so `LazyVStack` can virtualise them.
    private func flattenedRows(root: RemoteFileTreeNode, showHidden: Bool) -> [FlatRow] {
        var result: [FlatRow] = []
        func collect(_ node: RemoteFileTreeNode, depth: Int) {
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

struct RemoteFileTreeRowView: View {
    @ObservedObject var node: RemoteFileTreeNode
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

    // Children are rendered by the flat LazyVStack in RemoteFileTreeView —
    // this view only renders a single row.
    var body: some View {
        HStack(spacing: 5) {
            if node.isDirectory {
                if node.isLoading {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(mutedColor)
                        .frame(width: 10)
                }
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
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
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
                actions.onFileClicked?(node.remotePath)
            }
        }
        .contextMenu {
            if actions.isAIAgentRunning {
                Button("Reference in AI (@)") {
                    actions.onReferenceInAI?(node.remotePath)
                }
                Divider()
            }

            if node.isDirectory && !actions.isAIAgentRunning {
                Button("cd into") {
                    actions.onNavigate?(node.remotePath)
                }
                Divider()
            } else if !node.isDirectory {
                Button("cat") {
                    actions.onRunCommand?("cat \(RemoteExplorer.shellEscPath(node.remotePath))\r")
                }
                Divider()
            }
            Button("Copy Remote Path") {
                actions.onCopyPath?(node.remotePath)
            }
            Button("Paste Path to Terminal") {
                actions.onRunCommand?(RemoteExplorer.shellEscPath(node.remotePath))
            }
        }
    }

    // fileIcon(for:) is in Services/FileIcon.swift
}
