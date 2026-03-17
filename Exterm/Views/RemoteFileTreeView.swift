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

            Text("File explorer needs a reusable SSH connection.\nAdd to ~/.ssh/config:\n\nHost *\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-%r@%h:%p\n  ControlPersist 10m")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(nsColor: theme.chromeMuted).opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.sidebarBg))
    }
}

struct RemoteFileTreeView: View {
    @ObservedObject var root: RemoteFileTreeNode
    @ObservedObject var settings = SettingsObserver()
    var actions: FileTreeActions
    let host: String  // display name

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let showIcons = AppSettings.shared.explorerIconsEnabled
        let showHidden = AppSettings.shared.showHiddenFiles
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
            if AppSettings.shared.showExplorerHeader {
                HStack(spacing: 4) {
                    Image(systemName: root.session.icon)
                        .font(.system(size: 10))
                        .foregroundColor(accentColor)
                    Text(host.uppercased())
                        .font(explorerFont.weight(.semibold))
                        .foregroundColor(mutedColor)
                        .tracking(0.8)
                        .lineLimit(1)
                    Spacer()
                    if root.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }

            // Remote path breadcrumb
            HStack(spacing: 2) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundColor(mutedColor.opacity(0.6))
                Text(root.remotePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(mutedColor.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let children = filteredChildren(of: root, showHidden: showHidden)
                    ForEach(children) { node in
                        RemoteFileTreeRowView(
                            node: node, depth: 0, actions: actions,
                            explorerFont: explorerFont, showIcons: showIcons,
                            showHidden: showHidden, iconSize: fontSize,
                            textColor: textColor, mutedColor: mutedColor,
                            accentColor: accentColor, hoverColor: hoverColor
                        )
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(sidebarBgColor)
        .onAppear {
            root.loadChildren()
        }
    }

    private func filteredChildren(of node: RemoteFileTreeNode, showHidden: Bool) -> [RemoteFileTreeNode] {
        guard let children = node.children else { return [] }
        if showHidden { return children }
        return children.filter { !$0.name.hasPrefix(".") }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    }
                } else {
                    // Paste remote path to terminal
                    actions.onFileClicked?(node.remotePath)
                }
            }
            .contextMenu {
                if node.isDirectory {
                    Button("cd into directory") {
                        actions.onRunCommand?("cd \(node.remotePath)\n")
                    }
                }
                Button("Copy Remote Path") {
                    actions.onCopyPath?(node.remotePath)
                }
                Button("Paste Path to Terminal") {
                    actions.onRunCommand?(node.remotePath)
                }
            }

            if node.isExpanded, let children = node.children {
                let filtered = showHidden ? children : children.filter { !$0.name.hasPrefix(".") }
                ForEach(filtered) { child in
                    RemoteFileTreeRowView(
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

    // fileIcon(for:) and shellEscape(_:) are in Services/FileIcon.swift
}
