import Foundation

/// Per-tab state — single source of truth for everything a tab owns.
struct TabState {
    // Content type (terminal, browser, etc.)
    var contentType: ContentType = .terminal
    var contentState: ContentState = .terminal(TerminalContentState())

    // Terminal-specific fields (kept for backwards compatibility)
    // These delegate to contentState when it's a TerminalContentState.
    var workingDirectory: String
    var remoteSession: RemoteSessionType?
    var remoteWorkingDirectory: String?
    var shellPID: pid_t = 0
    var title: String
    var foregroundProcess: String = ""

    // AI Agent State
    /// Claude Code session ID currently running in this tab (detected via file watching)
    var agentSessionID: String?

    // Plugin UI State
    var expandedPluginIDs: Set<String> = []
    /// Section IDs the user has *explicitly* collapsed. Used to suppress auto-expand on first show.
    var userCollapsedSectionIDs: Set<String> = []
    var sidebarSectionHeights: [String: CGFloat] = [:]
    var sidebarScrollOffsets: [String: CGPoint] = [:]
    /// Per-plugin section order — keyed by plugin ID, values are ordered section IDs.
    var sidebarSectionOrder: [String: [String]] = [:]
    /// The plugin tab ID the user last selected in this terminal tab.
    var selectedPluginTabID: String? = nil
}

/// A pane is a leaf in the split tree. It has its own tab bar with multiple terminal tabs.
final class Pane {
    let id: UUID

    struct Tab {
        let id: UUID
        var state: TabState

        // Convenience accessors for backward compatibility
        var title: String {
            get { state.title }
            set {
                state.title = newValue
                state.contentState.title = newValue
            }
        }
        var workingDirectory: String {
            get { state.workingDirectory }
            set {
                state.workingDirectory = newValue
                state.contentState.updateTerminal { terminalState in
                    terminalState.workingDirectory = newValue
                }
            }
        }
        var remoteSession: RemoteSessionType? {
            get { state.remoteSession }
            set { state.remoteSession = newValue }
        }
        var remoteWorkingDirectory: String? {
            get { state.remoteWorkingDirectory }
            set { state.remoteWorkingDirectory = newValue }
        }
        var shellPID: pid_t {
            get { state.shellPID }
            set { state.shellPID = newValue }
        }

        var contentType: ContentType {
            get { state.contentType }
            set {
                state.contentType = newValue
                if state.contentState.contentType != newValue {
                    state.contentState = Pane.defaultContentState(
                        for: newValue,
                        title: state.title,
                        workingDirectory: state.workingDirectory
                    )
                }
            }
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex: Int = -1

    var activeTab: Tab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    init(id: UUID = UUID()) {
        self.id = id
    }

    init(id: UUID, tabs: [Tab], activeTabIndex: Int) {
        self.id = id
        self.tabs = tabs
        if tabs.isEmpty {
            self.activeTabIndex = -1
        } else {
            self.activeTabIndex = min(max(activeTabIndex, 0), tabs.count - 1)
        }
    }

    func cloned(withID id: UUID) -> Pane {
        Pane(id: id, tabs: tabs, activeTabIndex: activeTabIndex)
    }

    @discardableResult
    func addTab(workingDirectory: String, title: String? = nil) -> Int {
        addTab(contentType: .terminal, workingDirectory: workingDirectory, title: title)
    }

    /// Add a tab with a specific content type.
    @discardableResult
    func addTab(contentType: ContentType, workingDirectory: String = "~", title: String? = nil) -> Int {
        let defaultTitle =
            title
            ?? (contentType == .terminal
                ? workingDirectory.lastPathComponent
                : contentType.defaultTabTitle)

        let tab = Tab(
            id: UUID(),
            state: TabState(
                contentType: contentType,
                contentState: Self.defaultContentState(
                    for: contentType,
                    title: defaultTitle,
                    workingDirectory: workingDirectory
                ),
                workingDirectory: workingDirectory,
                title: defaultTitle
            )
        )
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return activeTabIndex
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabs.count,
            destinationIndex >= 0, destinationIndex < tabs.count,
            sourceIndex != destinationIndex
        else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)
        // Keep active tab pointing at the same tab
        if activeTabIndex == sourceIndex {
            activeTabIndex = destinationIndex
        } else if sourceIndex < activeTabIndex && destinationIndex >= activeTabIndex {
            activeTabIndex -= 1
        } else if sourceIndex > activeTabIndex && destinationIndex <= activeTabIndex {
            activeTabIndex += 1
        }
    }

    func removeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func setActiveTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }

    func updateTitle(at index: Int, _ title: String) {
        guard index >= 0, index < tabs.count else { return }
        // Skip transient command titles that flash briefly before the shell
        // prompt updates with the final state (e.g. "cd /path", "git switch branch")
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("cd ") || trimmed.hasPrefix("git switch ")
            || trimmed.hasPrefix("git checkout ")
        {
            return
        }
        tabs[index].title = title
    }

    func updateWorkingDirectory(at index: Int, _ path: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].workingDirectory = path
    }

    func updateRemoteSession(at index: Int, _ session: RemoteSessionType?) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].remoteSession = session
        if session == nil {
            tabs[index].remoteWorkingDirectory = nil
        }
    }

    func updateRemoteWorkingDirectory(at index: Int, _ path: String?) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].remoteWorkingDirectory = path
    }

    func updateForegroundProcess(at index: Int, _ process: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.foregroundProcess = process
        tabs[index].state.contentState.updateTerminal { terminalState in
            terminalState.foregroundProcess = process
        }
    }

    func updateShellPID(at index: Int, _ pid: pid_t) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].shellPID = pid
        tabs[index].state.contentState.updateTerminal { terminalState in
            terminalState.shellPID = pid
        }
    }

    func updateContentState(at index: Int, _ contentState: ContentState) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.contentType = contentState.contentType
        tabs[index].state.contentState = contentState
        tabs[index].state.title = contentState.title
        switch contentState {
        case .terminal(let terminalState):
            tabs[index].state.workingDirectory = terminalState.workingDirectory
            tabs[index].state.shellPID = terminalState.shellPID
            tabs[index].state.foregroundProcess = terminalState.foregroundProcess
        case .browser(let browserState):
            if browserState.url.isFileURL {
                tabs[index].state.workingDirectory = browserState.url.deletingLastPathComponent().path
            }
        case .editor(let editorState):
            if let filePath = editorState.filePath, !filePath.isEmpty {
                tabs[index].state.workingDirectory = (filePath as NSString).deletingLastPathComponent
            }
        case .imageViewer(let imageState):
            if !imageState.filePath.isEmpty {
                tabs[index].state.workingDirectory = (imageState.filePath as NSString).deletingLastPathComponent
            }
        case .markdownPreview(let markdownState):
            if !markdownState.filePath.isEmpty {
                tabs[index].state.workingDirectory = (markdownState.filePath as NSString).deletingLastPathComponent
            }
        case .pluginView:
            break
        }
    }

    func updateAgentSessionID(_ sessionID: String?) {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return }
        tabs[activeTabIndex].state.agentSessionID = sessionID
    }

    func updatePluginState(
        at index: Int,
        expanded: Set<String>,
        userCollapsed: Set<String>? = nil,
        sidebarSectionHeights: [String: CGFloat]? = nil,
        sidebarScrollOffsets: [String: CGPoint]? = nil,
        sidebarSectionOrder: [String: [String]]? = nil,
        selectedPluginTabID: String? = nil
    ) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.expandedPluginIDs = expanded
        if let userCollapsed {
            tabs[index].state.userCollapsedSectionIDs = userCollapsed
        }
        if let sidebarSectionHeights {
            tabs[index].state.sidebarSectionHeights = sidebarSectionHeights
        }
        if let sidebarScrollOffsets {
            tabs[index].state.sidebarScrollOffsets = sidebarScrollOffsets
        }
        if let sidebarSectionOrder {
            tabs[index].state.sidebarSectionOrder = sidebarSectionOrder
        }
        if let selectedPluginTabID {
            tabs[index].state.selectedPluginTabID = selectedPluginTabID
        }
    }

    /// Remove and return a tab without destroying its view. Used for cross-pane drag.
    @discardableResult
    func extractTab(at index: Int) -> Tab? {
        guard index >= 0, index < tabs.count else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = max(tabs.count - 1, 0)
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        return tab
    }

    /// Insert an existing tab at a specific index. Used for cross-pane drag.
    func insertTab(_ tab: Tab, at index: Int) {
        let clampedIndex = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clampedIndex)
        activeTabIndex = clampedIndex
    }

    func stopAll() {
        tabs.removeAll()
    }

    private static func defaultContentState(
        for contentType: ContentType,
        title: String,
        workingDirectory: String
    ) -> ContentState {
        switch contentType {
        case .terminal:
            return .terminal(TerminalContentState(title: title, workingDirectory: workingDirectory))
        case .browser:
            return .browser(BrowserContentState(title: title, url: ContentType.newTabURL))
        case .editor:
            return .editor(EditorContentState(title: title))
        case .imageViewer:
            return .imageViewer(ImageViewerContentState(title: title, filePath: ""))
        case .markdownPreview:
            return .markdownPreview(MarkdownPreviewContentState(title: title, filePath: ""))
        case .pluginView:
            return .pluginView(PluginViewContentState(title: title))
        }
    }
}
