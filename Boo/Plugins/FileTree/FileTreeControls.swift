import SwiftUI

// MARK: - Filter Bar

struct FileTreeFilterBar: View {
    @ObservedObject var filter: FileTreeFilterModel
    var focused: FocusState<Bool>.Binding
    var style: RowStyle
    var onCollapseAll: () -> Void
    var onRefresh: (@MainActor () -> Void)? = nil
    var onSubmit: () -> Void
    var onMoveIntoTree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 12))
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

            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.mutedColor)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            Button(action: onCollapseAll) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.mutedColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse All Folders")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - Navigation

/// Folder navigation for the explorer root, rebuilt by the plugin every cycle.
struct FileTreeNavigation {
    var mode: ExplorerNavigationMode
    /// Root label for the bar, computed by the plugin so it matches the generation key.
    var displayPath: String
    var isDetached: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    /// False while an AI agent holds the terminal — typing `cd` would land in its prompt.
    var canSendToTerminal: Bool
    /// Make a folder the root: browses or `cd`s depending on `mode`.
    var open: @MainActor (String) -> Void
    /// Make a folder the root inside the explorer, whatever the mode (row "Browse Folder").
    var browse: @MainActor (String) -> Void
    var goBack: @MainActor () -> Void
    var goForward: @MainActor () -> Void
    /// Re-link the explorer to the terminal's working directory.
    var attach: @MainActor () -> Void
    /// `cd` the terminal into the folder the explorer shows, and re-link.
    var cdTerminalHere: @MainActor () -> Void
}

struct FileTreeNavigationBar: View {
    var navigation: FileTreeNavigation
    var rootPath: String
    var style: RowStyle

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.left", help: "Back (⌥←)", enabled: navigation.canGoBack, action: navigation.goBack)
            button(
                "chevron.right", help: "Forward (⌥→)", enabled: navigation.canGoForward,
                action: navigation.goForward)
            button(
                "arrow.up",
                help: navigation.mode == .terminal ? "cd to Enclosing Folder (⌥↑)" : "Enclosing Folder (⌥↑)",
                enabled: rootPath != "/"
            ) {
                navigation.open((rootPath as NSString).deletingLastPathComponent)
            }

            Text(navigation.displayPath)
                .font(style.font)
                .foregroundStyle(navigation.isDetached ? style.textColor : style.mutedColor)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .help(rootPath)

            if navigation.isDetached {
                if navigation.canSendToTerminal {
                    button("terminal", help: "cd Terminal Here", enabled: true, action: navigation.cdTerminalHere)
                }
                button(
                    "location.fill", help: "Back to Terminal Folder", enabled: true, tint: style.accentColor,
                    action: navigation.attach)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.mutedColor.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .help("Following the terminal's folder")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func button(
        _ icon: String, help: String, enabled: Bool, tint: Color? = nil, action: @escaping @MainActor () -> Void
    ) -> some View {
        SidebarIconButton(
            systemName: icon, help: help, tint: enabled ? (tint ?? style.textColor) : style.mutedColor,
            enabled: enabled, size: 12, weight: .semibold, action: action)
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
