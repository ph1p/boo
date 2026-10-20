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
    var foregroundProcessPID: pid_t?
    var foregroundProcessCategory: String?
    var foregroundProcessMetadata: [String: String] = [:]

    // AI Agent State
    /// Claude Code session ID currently running in this tab (detected via file watching)
    var agentSessionID: String?

    var hasActivity: Bool = false
    var isCommandRunning: Bool = false
    /// OSC 9;4 progress; not persisted.
    var progress: TerminalProgress?
    /// A session recording is running; not persisted.
    var isRecording: Bool = false

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

/// A named, colored run of adjacent tabs in one pane's tab bar. Collapsed,
/// it shows as its chip alone.
struct TabGroup: Equatable {
    let id: UUID
    var name: String
    var color: WorkspaceColor
    var isCollapsed = false
}

/// A pane is a leaf in the split tree. It has its own tab bar with multiple terminal tabs.
final class Pane {
    let id: UUID

    struct Tab {
        let id: UUID
        var state: TabState
        /// The `TabGroup` in this pane the tab belongs to.
        var groupID: UUID?

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
    /// Tab groups of this pane; a group sits wherever its tabs are.
    private(set) var groups: [TabGroup] = []

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
        let pane = Pane(id: id, tabs: tabs, activeTabIndex: activeTabIndex)
        pane.groups = groups
        return pane
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
        tabs[destinationIndex].groupID = Self.groupAfterMove(
            tab.groupID, left: tabAt(destinationIndex - 1)?.groupID,
            right: tabAt(destinationIndex + 1)?.groupID,
            alone: !tabs.contains { $0.id != tab.id && $0.groupID != nil && $0.groupID == tab.groupID })
        pruneGroups()
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
        extractTab(at: index)
    }

    func setActiveTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
        // A tab picked by shortcut or palette shows its collapsed group again.
        if let gid = tabs[index].groupID, let g = groups.firstIndex(where: { $0.id == gid }) {
            groups[g].isCollapsed = false
        }
    }

    // MARK: - Tab Groups

    func group(id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Tab hidden inside a collapsed group.
    func isTabHidden(at index: Int) -> Bool {
        group(id: tabAt(index)?.groupID)?.isCollapsed == true
    }

    /// Index of the first tab of each group: where its chip is drawn.
    func isFirstTabOfGroup(at index: Int) -> Bool {
        guard let gid = tabAt(index)?.groupID else { return false }
        return tabAt(index - 1)?.groupID != gid
    }

    func tabIndices(inGroup id: UUID) -> [Int] {
        tabs.indices.filter { tabs[$0].groupID == id }
    }

    /// Drops `source` onto `target`: joins the target's group, or makes a new
    /// group of both. The source moves next to the group so it stays one run.
    @discardableResult
    func groupTab(at source: Int, with target: Int) -> UUID? {
        guard source != target, tabs.indices.contains(source), tabs.indices.contains(target) else { return nil }
        guard let gid = tabs[target].groupID ?? createGroup(withTabsAt: [target]) else { return nil }
        addTab(at: source, toGroup: gid)
        return gid
    }

    /// Makes a new group of the given tabs, gathered into one run where the
    /// first of them sits, in tab order. Named after the first tab's folder.
    @discardableResult
    func createGroup(withTabsAt indices: [Int]) -> UUID? {
        let picked = Set(indices.filter { tabs.indices.contains($0) })
        guard let first = picked.min() else { return nil }
        let gid = UUID()
        let name = (tabs[first].workingDirectory as NSString).lastPathComponent
        groups.append(TabGroup(id: gid, name: name.isEmpty ? "Group" : name, color: nextGroupColor()))
        let activeID = activeTabID
        var members = picked.sorted().map { tabs[$0] }
        for i in members.indices { members[i].groupID = gid }
        let before = tabs.indices.filter { $0 < first && !picked.contains($0) }.map { tabs[$0] }
        let after = tabs.indices.filter { $0 > first && !picked.contains($0) }.map { tabs[$0] }
        tabs = before + members + after
        restoreActive(activeID)
        pruneGroups()
        return gid
    }

    /// Moves the tab to the end of group `id` and makes it a member.
    func addTab(at index: Int, toGroup id: UUID) {
        guard tabs.indices.contains(index), group(id: id) != nil, tabs[index].groupID != id else { return }
        let activeID = activeTabID
        var tab = tabs.remove(at: index)
        tab.groupID = id
        let end = (tabs.lastIndex { $0.groupID == id } ?? (index - 1)) + 1
        tabs.insert(tab, at: min(max(end, 0), tabs.count))
        restoreActive(activeID)
        pruneGroups()
    }

    /// Moves a whole group so it starts at `index` (an insertion index in the
    /// current tab order). A spot inside another group snaps to that group's
    /// nearer edge, so groups never interleave.
    func moveGroup(_ id: UUID, to index: Int) {
        let members = tabIndices(inGroup: id)
        guard let first = members.first, let last = members.last, index < first || index > last + 1 else { return }
        let activeID = activeTabID
        let block = Array(tabs[first...last])
        var rest = tabs
        rest.removeSubrange(first...last)
        var dest = min(max(index > last ? index - block.count : index, 0), rest.count)
        if dest > 0, dest < rest.count, let other = rest[dest].groupID, rest[dest - 1].groupID == other {
            let start = rest.firstIndex { $0.groupID == other } ?? dest
            let end = (rest.lastIndex { $0.groupID == other } ?? dest) + 1
            dest = dest - start <= end - dest ? start : end
        }
        rest.insert(contentsOf: block, at: dest)
        tabs = rest
        restoreActive(activeID)
    }

    /// Removes a group and its tabs, for moving them to another pane with
    /// `insertGroup`. The views stay alive like `extractTab`'s.
    func extractGroup(_ id: UUID) -> (group: TabGroup, tabs: [Tab])? {
        guard let group = group(id: id) else { return nil }
        var moved: [Tab] = []
        while let i = tabs.lastIndex(where: { $0.groupID == id }), let tab = extractTab(at: i) {
            moved.insert(tab, at: 0)
        }
        return (group, moved)
    }

    /// Inserts tabs taken out by `extractGroup` as one group at `index`
    /// (snapped out of any group there). The first of them becomes active.
    func insertGroup(_ group: TabGroup, tabs moved: [Tab], at index: Int) {
        guard !moved.isEmpty else { return }
        var dest = min(max(index, 0), tabs.count)
        if dest > 0, dest < tabs.count, let other = tabs[dest].groupID, tabs[dest - 1].groupID == other {
            dest = (tabs.lastIndex { $0.groupID == other } ?? dest) + 1
        }
        var group = group
        group.isCollapsed = false
        groups.removeAll { $0.id == group.id }
        groups.append(group)
        tabs.insert(
            contentsOf: moved.map { tab -> Tab in
                var tab = tab
                tab.groupID = group.id
                return tab
            }, at: dest)
        activeTabIndex = dest
        pruneGroups()
    }

    /// Index a new tab started from tab `index` lands at: the end of that
    /// tab's group, or nil when it isn't grouped.
    func groupEndIndex(forTabAt index: Int) -> Int? {
        guard let gid = tabAt(index)?.groupID, let last = tabs.lastIndex(where: { $0.groupID == gid }) else {
            return nil
        }
        return last + 1
    }

    /// Takes the tab out of its group, moving it past the group's end.
    func removeTabFromGroup(at index: Int) {
        guard let gid = tabAt(index)?.groupID else { return }
        let activeID = activeTabID
        let tab = tabs.remove(at: index)
        let end = (tabs.lastIndex { $0.groupID == gid } ?? (index - 1)) + 1
        var freed = tab
        freed.groupID = nil
        tabs.insert(freed, at: min(end, tabs.count))
        restoreActive(activeID)
        pruneGroups()
    }

    func ungroup(_ id: UUID) {
        for i in tabs.indices where tabs[i].groupID == id { tabs[i].groupID = nil }
        pruneGroups()
    }

    func updateGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[g])
    }

    /// Collapses or expands `id`. A collapsed group can't hold the active tab,
    /// so the caller switches to `outsideTabIndex(of:)` first; nil when every
    /// tab of the pane is in the group, and the group stays open.
    func outsideTabIndex(of id: UUID) -> Int? {
        let members = tabIndices(inGroup: id)
        guard let first = members.first, let last = members.last else { return nil }
        if last + 1 < tabs.count, !isTabHidden(at: last + 1) { return last + 1 }
        return (0..<first).reversed().first { !isTabHidden(at: $0) }
            ?? (last + 1 < tabs.count ? (last + 1..<tabs.count).first { !isTabHidden(at: $0) } : nil)
    }

    /// Restores groups saved with the session; `memberships` is per tab, in order.
    func restoreGroups(_ saved: [TabGroup], memberships: [UUID?]) {
        groups = saved
        let known = Set(saved.map(\.id))
        for (i, gid) in memberships.enumerated() where i < tabs.count {
            tabs[i].groupID = gid.flatMap { known.contains($0) ? $0 : nil }
        }
        pruneGroups()
    }

    private var activeTabID: UUID? { activeTab?.id }

    private func restoreActive(_ id: UUID?) {
        if let id, let i = tabs.firstIndex(where: { $0.id == id }) { activeTabIndex = i }
    }

    private func tabAt(_ index: Int) -> Tab? {
        tabs.indices.contains(index) ? tabs[index] : nil
    }

    private func nextGroupColor() -> WorkspaceColor {
        let palette = WorkspaceColor.allCases.filter { $0 != .none }
        let used = Set(groups.map(\.color))
        return palette.first { !used.contains($0) } ?? palette[groups.count % palette.count]
    }

    /// Where a moved tab belongs: inside a group when dropped between two of
    /// its tabs, out of its own group once it no longer touches it.
    static func groupAfterMove(_ own: UUID?, left: UUID?, right: UUID?, alone: Bool) -> UUID? {
        if let left, left == right { return left }
        guard let own else { return nil }
        if alone || own == left || own == right { return own }
        return nil
    }

    /// Drops groups that lost their tabs, and splits a group whose tabs are no
    /// longer one run, keeping the first run.
    private func pruneGroups() {
        var seenEnded = Set<UUID>()
        var previous: UUID?
        for i in tabs.indices {
            let gid = tabs[i].groupID
            if let gid, gid != previous, seenEnded.contains(gid) { tabs[i].groupID = nil }
            if let previous, previous != tabs[i].groupID { seenEnded.insert(previous) }
            previous = tabs[i].groupID
        }
        let live = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !live.contains($0.id) }
    }

    @discardableResult
    func setActivity(_ active: Bool, at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        guard tabs[index].state.hasActivity != active else { return false }
        tabs[index].state.hasActivity = active
        return true
    }

    @discardableResult
    func setRecording(_ recording: Bool, at index: Int) -> Bool {
        guard index >= 0, index < tabs.count, tabs[index].state.isRecording != recording else { return false }
        tabs[index].state.isRecording = recording
        return true
    }

    /// False when nothing changed, so callers can skip the redraw.
    @discardableResult
    func setProgress(_ progress: TerminalProgress?, at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        let old = tabs[index].state.progress
        tabs[index].state.progress = progress
        return old?.state != progress?.state || old?.percent != progress?.percent
    }

    func setCommandRunning(_ running: Bool, at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.isCommandRunning = running
    }

    func runningCommandTabIndex() -> Int? {
        tabs.indices.first { tabs[$0].state.isCommandRunning }
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

    func updateForegroundProcess(
        at index: Int,
        _ process: String,
        pid: pid_t? = nil,
        category: String? = nil,
        metadata: [String: String] = [:]
    ) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].state.foregroundProcess = process
        tabs[index].state.foregroundProcessPID = pid
        tabs[index].state.foregroundProcessCategory = category
        tabs[index].state.foregroundProcessMetadata = metadata
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
            tabs[index].state.foregroundProcessPID = nil
            tabs[index].state.foregroundProcessCategory = ProcessIcon.category(for: terminalState.foregroundProcess)
            tabs[index].state.foregroundProcessMetadata = [:]
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
        case .castPlayer(let castState):
            if !castState.filePath.isEmpty {
                tabs[index].state.workingDirectory = (castState.filePath as NSString).deletingLastPathComponent
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
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        pruneGroups()
        return tab
    }

    /// Insert an existing tab at a specific index. Used for cross-pane drag.
    func insertTab(_ tab: Tab, at index: Int) {
        let clampedIndex = min(max(index, 0), tabs.count)
        var tab = tab
        // Groups belong to a pane; a tab from another pane arrives ungrouped.
        if group(id: tab.groupID) == nil { tab.groupID = nil }
        tabs.insert(tab, at: clampedIndex)
        activeTabIndex = clampedIndex
        tabs[clampedIndex].groupID = Self.groupAfterMove(
            tab.groupID, left: tabAt(clampedIndex - 1)?.groupID,
            right: tabAt(clampedIndex + 1)?.groupID, alone: false)
        if let gid = tabs[clampedIndex].groupID { updateGroup(gid) { $0.isCollapsed = false } }
        pruneGroups()
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
        case .castPlayer:
            return .castPlayer(CastPlayerContentState(title: title, filePath: ""))
        }
    }
}
