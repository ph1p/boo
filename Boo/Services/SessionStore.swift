import Cocoa
import Foundation

// MARK: - Codable session snapshot types

struct SessionTab: Codable, Sendable {
    let contentState: ContentState?
    // Remote sessions are intentionally omitted — only local state is persisted.
    // Sidebar state — optional so old session.json files decode without error.
    let expandedPluginIDs: [String]?
    let userCollapsedSectionIDs: [String]?
    let sidebarSectionHeights: [String: Double]?
    let sidebarScrollOffsets: [String: [Double]]?
    let sidebarSectionOrder: [String: [String]]?
    let selectedPluginTabID: String?
    let groupID: UUID?
    /// ID the tab's scrollback was saved under on quit (see ScrollbackStore).
    let scrollbackID: UUID?

    init(
        contentState: ContentState? = nil,
        expandedPluginIDs: [String]? = nil,
        userCollapsedSectionIDs: [String]? = nil,
        sidebarSectionHeights: [String: Double]? = nil,
        sidebarScrollOffsets: [String: [Double]]? = nil,
        sidebarSectionOrder: [String: [String]]? = nil,
        selectedPluginTabID: String? = nil,
        groupID: UUID? = nil,
        scrollbackID: UUID? = nil
    ) {
        self.contentState = contentState
        self.expandedPluginIDs = expandedPluginIDs
        self.userCollapsedSectionIDs = userCollapsedSectionIDs
        self.sidebarSectionHeights = sidebarSectionHeights
        self.sidebarScrollOffsets = sidebarScrollOffsets
        self.sidebarSectionOrder = sidebarSectionOrder
        self.selectedPluginTabID = selectedPluginTabID
        self.groupID = groupID
        self.scrollbackID = scrollbackID
    }
}

struct SessionTabGroup: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let color: String
    let collapsed: Bool

    init(_ group: TabGroup) {
        id = group.id
        name = group.name
        color = group.color.rawValue
        collapsed = group.isCollapsed
    }

    var tabGroup: TabGroup {
        TabGroup(id: id, name: name, color: WorkspaceColor(rawValue: color) ?? .blue, isCollapsed: collapsed)
    }
}

struct SessionPane: Codable, Sendable {
    let id: UUID
    let tabs: [SessionTab]
    let activeTabIndex: Int
    /// Optional so sessions saved before tab groups decode.
    var groups: [SessionTabGroup]? = nil
}

struct SessionWorkspace: Codable, Sendable {
    let id: UUID
    let folderPath: String
    let customName: String?
    let color: String  // WorkspaceColor.rawValue
    let customColorRed: CGFloat?
    let customColorGreen: CGFloat?
    let customColorBlue: CGFloat?
    let isPinned: Bool
    let splitTree: SplitTree
    let panes: [SessionPane]
    let activePaneID: UUID
    // Per-workspace sidebar state — optional for backwards compatibility
    let sidebarIsVisible: Bool?
    let sidebarWidth: Double?
}

/// One main window: its workspaces plus window chrome.
struct SessionWindow: Codable, Sendable {
    var activeWorkspaceIndex: Int
    var workspaces: [SessionWorkspace]
    /// Non-fullscreen frame in screen coordinates: [x, y, width, height].
    var frame: [Double]? = nil
    /// Display `frame` was on (see `WindowPlacement`).
    var screenID: String? = nil
    var screenFrame: [Double]? = nil
    /// Where the window lived before macOS moved it off an unplugged display;
    /// restored once that display is back.
    var homePlacement: WindowPlacement? = nil
    var isFullScreen: Bool? = nil
    /// Window-level sidebar state (fallback when per-workspace state is off).
    var sidebarIsVisible: Bool? = nil
    var sidebarWidth: Double? = nil

    var frameRect: NSRect? {
        guard let frame, frame.count == 4, frame[2] > 0, frame[3] > 0 else { return nil }
        return NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }

    var placement: WindowPlacement? {
        guard let frame, frameRect != nil else { return nil }
        return WindowPlacement(frame: frame, screenID: screenID, screenFrame: screenFrame)
    }

    var sidebarState: SidebarWorkspaceState? {
        guard sidebarIsVisible != nil || sidebarWidth != nil else { return nil }
        return SidebarWorkspaceState(
            isVisible: sidebarIsVisible,
            width: sidebarWidth.flatMap { $0 > 0 ? CGFloat($0) : nil }
        )
    }
}

/// Session file. Version 2 stores every window in `windows`; the top-level
/// `activeWorkspaceIndex`/`workspaces` mirror the key window so older builds
/// (version 1, no `windows`) still restore something.
struct SessionSnapshot: Codable, Sendable {
    let activeWorkspaceIndex: Int
    let workspaces: [SessionWorkspace]
    var version: Int? = nil
    var windows: [SessionWindow]? = nil
    var keyWindowIndex: Int? = nil
    /// The orchestrator conversation and the task worktrees it owns.
    var orchestrator: OrchestratorSession? = nil
    /// The quick terminal's tabs.
    var quickTerminal: QuickTerminalSession? = nil

    /// Every saved window; a version 1 file is a single window.
    var allWindows: [SessionWindow] {
        if let windows, !windows.isEmpty { return windows }
        return [SessionWindow(activeWorkspaceIndex: activeWorkspaceIndex, workspaces: workspaces)]
    }

    /// Index into `allWindows` of the window to make key.
    var resolvedKeyWindowIndex: Int {
        let count = allWindows.count
        return min(max(keyWindowIndex ?? 0, 0), count - 1)
    }

    init(activeWorkspaceIndex: Int, workspaces: [SessionWorkspace]) {
        self.activeWorkspaceIndex = activeWorkspaceIndex
        self.workspaces = workspaces
    }

    /// Version 2 snapshot of `windows` with the legacy mirror of the key window.
    init(windows: [SessionWindow], keyWindowIndex: Int) {
        // Windows that lost every workspace (closing) only survive when nothing else does.
        let nonEmpty = windows.enumerated().filter { !$0.element.workspaces.isEmpty }
        let kept = nonEmpty.isEmpty ? Array(windows.enumerated().prefix(1)) : nonEmpty
        let all = kept.map(\.element)
        let keyIndex = kept.firstIndex { $0.offset == keyWindowIndex } ?? 0
        let mirror = all.isEmpty ? nil : all[keyIndex]
        self.activeWorkspaceIndex = mirror?.activeWorkspaceIndex ?? 0
        self.workspaces = mirror?.workspaces ?? []
        self.version = 2
        self.windows = all
        self.keyWindowIndex = keyIndex
    }
}

// MARK: - SessionStore

enum SessionStore {
    private nonisolated(unsafe) static var _testFilePath: String? = nil

    /// Serial queue that serializes all background encode+write operations.
    /// Last-write-wins: rapid saves enqueue in order; each one overwrites the previous.
    private static let writeQueue = DispatchQueue(
        label: "dev.boo.SessionStore.write", qos: .utility)

    /// Override the storage path. Pass `nil` to revert to the default. Tests only.
    static func overrideFilePathForTesting(_ path: String?) {
        _testFilePath = path
    }

    /// Under XCTest every save goes to a per-process temp file, so test
    /// controllers (most persist by default) never touch ~/.boo/session.json.
    private static let xctestFile: String? =
        NSClassFromString("XCTestCase") == nil
        ? nil
        : (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-test-session-\(ProcessInfo.processInfo.processIdentifier).json")

    private static var sessionFile: String {
        _testFilePath ?? xctestFile ?? BooPaths.configDir.appendingPathComponent("session.json")
    }

    /// Build a single-window `SessionSnapshot` from `appState`.
    /// Must be called on the main thread because AppState/Workspace/Pane are not thread-safe.
    private static func buildSnapshot(appState: AppState) -> SessionSnapshot {
        SessionSnapshot(windows: [buildWindow(appState: appState)], keyWindowIndex: 0)
    }

    /// Build one window's session state from `appState`. Main thread only.
    static func buildWindow(appState: AppState) -> SessionWindow {
        // tmux windows live in tmux; the next attach shows them again.
        let saved = appState.workspaces.filter { $0.tmuxWindowID == nil }
        let active =
            appState.workspaces.indices.contains(appState.activeWorkspaceIndex)
            ? appState.workspaces[appState.activeWorkspaceIndex] : nil
        let workspaces = saved.map { ws -> SessionWorkspace in
            ws.normalizePaneState()
            let panes = ws.panes.values.map { pane -> SessionPane in
                let tabs = pane.tabs.map { tab in
                    SessionTab(
                        contentState: tab.contentType.isPersistable ? tab.state.contentState : nil,
                        expandedPluginIDs: Array(tab.state.expandedPluginIDs),
                        userCollapsedSectionIDs: Array(tab.state.userCollapsedSectionIDs),
                        sidebarSectionHeights: tab.state.sidebarSectionHeights.mapValues {
                            Double($0)
                        },
                        sidebarScrollOffsets: tab.state.sidebarScrollOffsets.mapValues {
                            [$0.x, $0.y]
                        },
                        sidebarSectionOrder: tab.state.sidebarSectionOrder,
                        selectedPluginTabID: tab.state.selectedPluginTabID,
                        groupID: tab.groupID,
                        scrollbackID: tab.contentType == .terminal ? tab.id : nil
                    )
                }
                return SessionPane(
                    id: pane.id,
                    tabs: tabs,
                    activeTabIndex: pane.activeTabIndex,
                    groups: pane.groups.isEmpty ? nil : pane.groups.map(SessionTabGroup.init)
                )
            }

            var red: CGFloat? = nil
            var green: CGFloat? = nil
            var blue: CGFloat? = nil
            if let cc = ws.customColor {
                let rgb = cc.usingColorSpace(.sRGB) ?? cc
                red = rgb.redComponent
                green = rgb.greenComponent
                blue = rgb.blueComponent
            }

            return SessionWorkspace(
                id: ws.id,
                folderPath: ws.folderPath,
                customName: ws.customName,
                color: ws.color.rawValue,
                customColorRed: red,
                customColorGreen: green,
                customColorBlue: blue,
                isPinned: ws.isPinned,
                splitTree: ws.splitTree,
                panes: panes,
                activePaneID: ws.activePaneID,
                sidebarIsVisible: ws.sidebarState.isVisible,
                sidebarWidth: ws.sidebarState.width.map { Double($0) }
            )
        }

        return SessionWindow(
            activeWorkspaceIndex: saved.firstIndex { $0 === active }
                ?? min(appState.activeWorkspaceIndex, saved.count - 1),
            workspaces: workspaces
        )
    }

    /// Write a pre-built snapshot to disk (encode + atomic write).
    /// Safe to call on any thread.
    private static func writeSnapshot(_ snapshot: SessionSnapshot, to path: String) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            booLog(.error, .app, "Failed to save session: \(error)")
        }
    }

    /// Synchronous save — snapshot phase and write phase both happen on the caller's thread.
    /// Used by `AppDelegate.applicationWillTerminate` so the final state is not lost.
    /// Must be called on the main thread.
    static func save(appState: AppState) {
        save(buildSnapshot(appState: appState))
    }

    /// Synchronous write of a pre-built snapshot (multi-window saves).
    static func save(_ snapshot: SessionSnapshot) {
        let path = sessionFile
        // Route through the write queue so any pending async writes land first;
        // this snapshot is guaranteed to be the final on-disk state.
        writeQueue.sync {
            writeSnapshot(snapshot, to: path)
        }
    }

    /// Async save — snapshot is taken synchronously on the current (main) thread,
    /// then the encode+write is dispatched to a private serial background queue.
    /// Callers on hot paths (tab open, workspace switch) should prefer this variant.
    /// Must be called on the main thread.
    static func saveAsync(appState: AppState) {
        saveAsync(buildSnapshot(appState: appState))
    }

    /// Async write of a pre-built snapshot (multi-window saves).
    static func saveAsync(_ snapshot: SessionSnapshot) {
        let path = sessionFile
        writeQueue.async {
            writeSnapshot(snapshot, to: path)
        }
    }

    /// Returns nil when no session file exists or the file cannot be decoded.
    static func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: sessionFile) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            debugLog("[SessionStore] Failed to load session: \(error)")
            return nil
        }
    }

    /// Reconstruct Workspace objects from a snapshot, skipping any workspaces
    /// whose folderPath no longer exists on disk.
    static func workspaces(from snapshot: SessionSnapshot) -> [Workspace] {
        workspaces(from: snapshot.allWindows[0])
    }

    /// Reconstruct one window's Workspace objects (missing folders skipped).
    static func workspaces(from window: SessionWindow) -> [Workspace] {
        let restored: [Workspace] = window.workspaces.compactMap { sw -> Workspace? in
            // Only restore workspaces whose root folder still exists.
            guard FileManager.default.fileExists(atPath: sw.folderPath) else {
                debugLog("[SessionStore] Skipping workspace at \(sw.folderPath) — path not found")
                return nil
            }

            let ws = Workspace(
                folderPath: sw.folderPath,
                id: sw.id,
                splitTree: sw.splitTree,
                activePaneID: sw.activePaneID
            )
            ws.customName = sw.customName
            ws.color = WorkspaceColor(rawValue: sw.color) ?? .none
            ws.isPinned = sw.isPinned
            if let r = sw.customColorRed, let g = sw.customColorGreen, let b = sw.customColorBlue {
                ws.customColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            let defaultSidebarState = Workspace.defaultSidebarState()
            // Older builds could persist a pre-layout width of 0 (captured before the
            // first layout pass); a non-positive width is never valid, fall back to default.
            let storedSidebarWidth = sw.sidebarWidth.flatMap { $0 > 0 ? CGFloat($0) : nil }
            ws.sidebarState = SidebarWorkspaceState(
                isVisible: sw.sidebarIsVisible ?? defaultSidebarState.isVisible,
                width: storedSidebarWidth ?? defaultSidebarState.width
            )

            // Build a lookup so we can match panes to split-tree leaf IDs
            let paneByID = Dictionary(uniqueKeysWithValues: sw.panes.map { ($0.id, $0) })
            let leafIDs = sw.splitTree.leafIDs

            for leafID in leafIDs {
                let pane = Pane(id: leafID)
                if let sp = paneByID[leafID], !sp.tabs.isEmpty {
                    for tab in sp.tabs {
                        let restoredState =
                            if let contentState = tab.contentState,
                                contentState.contentType.isPersistable,
                                isContentStateRestorable(contentState)
                            {
                                contentState
                            } else {
                                ContentState.terminal(
                                    TerminalContentState(workingDirectory: sw.folderPath)
                                )
                            }
                        let idx = pane.addTab(
                            contentType: restoredState.contentType,
                            workingDirectory: restoredWorkingDirectory(
                                for: restoredState,
                                fallback: sw.folderPath,
                                workspacePath: sw.folderPath
                            ),
                            title: restoredState.title
                        )
                        pane.updateContentState(at: idx, restoredState)
                        if let savedID = tab.scrollbackID, restoredState.contentType == .terminal {
                            ScrollbackStore.schedule(savedID: savedID, for: pane.tabs[idx].id)
                        }
                        pane.updatePluginState(
                            at: idx,
                            expanded: Set(tab.expandedPluginIDs ?? []),
                            userCollapsed: Set(tab.userCollapsedSectionIDs ?? []),
                            sidebarSectionHeights: (tab.sidebarSectionHeights ?? [:]).mapValues {
                                CGFloat($0)
                            },
                            sidebarScrollOffsets: (tab.sidebarScrollOffsets ?? [:])
                                .compactMapValues { arr in
                                    guard arr.count == 2 else { return nil }
                                    return CGPoint(x: arr[0], y: arr[1])
                                },
                            sidebarSectionOrder: tab.sidebarSectionOrder ?? [:],
                            selectedPluginTabID: tab.selectedPluginTabID
                        )
                    }
                    if let groups = sp.groups {
                        pane.restoreGroups(groups.map(\.tabGroup), memberships: sp.tabs.map(\.groupID))
                    }
                    let safeIndex = min(max(sp.activeTabIndex, 0), sp.tabs.count - 1)
                    pane.setActiveTab(safeIndex)
                } else {
                    // Fallback: single tab at the workspace root
                    pane.addTab(workingDirectory: sw.folderPath)
                }
                ws.restorePane(pane)
            }

            ws.normalizePaneState()

            return ws
        }

        AppState.ensureUniquePaneIDsAcrossWorkspaces(restored)
        return restored
    }

    /// Resolve which restored workspace should be active.
    ///
    /// The snapshot stores the active workspace as an array index, but workspaces whose
    /// folders no longer exist are dropped during restore, shifting indices. Match by the
    /// saved active workspace's ID against the restored set; fall back to a clamped index
    /// only when the active workspace itself was dropped.
    static func resolvedActiveIndex(snapshot: SessionSnapshot, restoredIDs: [UUID]) -> Int {
        resolvedActiveIndex(window: snapshot.allWindows[0], restoredIDs: restoredIDs)
    }

    static func resolvedActiveIndex(window: SessionWindow, restoredIDs: [UUID]) -> Int {
        guard !restoredIDs.isEmpty else { return 0 }
        if window.activeWorkspaceIndex >= 0,
            window.activeWorkspaceIndex < window.workspaces.count
        {
            let activeID = window.workspaces[window.activeWorkspaceIndex].id
            if let idx = restoredIDs.firstIndex(of: activeID) { return idx }
        }
        return min(max(window.activeWorkspaceIndex, 0), restoredIDs.count - 1)
    }

    /// Whether any of the window's workspace folders still exists.
    static func hasRestorableWorkspace(_ window: SessionWindow) -> Bool {
        window.workspaces.contains { FileManager.default.fileExists(atPath: $0.folderPath) }
    }

    private static func isContentStateRestorable(_ state: ContentState) -> Bool {
        switch state {
        case .editor(let s):
            guard let path = s.filePath, !path.isEmpty else { return true }
            return FileManager.default.fileExists(atPath: path)
        case .imageViewer(let s):
            return s.filePath.isEmpty || FileManager.default.fileExists(atPath: s.filePath)
        case .markdownPreview(let s):
            return s.filePath.isEmpty || FileManager.default.fileExists(atPath: s.filePath)
        case .castPlayer(let s):
            return !s.filePath.isEmpty && FileManager.default.fileExists(atPath: s.filePath)
        default:
            return true
        }
    }

    private static func restoredWorkingDirectory(
        for contentState: ContentState,
        fallback: String,
        workspacePath: String
    ) -> String {
        switch contentState {
        case .terminal(let terminalState):
            return terminalState.workingDirectory
        case .browser(let browserState):
            if browserState.url.isFileURL {
                return browserState.url.deletingLastPathComponent().path
            }
        case .editor(let editorState):
            if let filePath = editorState.filePath, !filePath.isEmpty {
                return (filePath as NSString).deletingLastPathComponent
            }
        case .imageViewer(let imageState):
            if !imageState.filePath.isEmpty {
                return (imageState.filePath as NSString).deletingLastPathComponent
            }
        case .markdownPreview(let markdownState):
            if !markdownState.filePath.isEmpty {
                return (markdownState.filePath as NSString).deletingLastPathComponent
            }
        case .castPlayer(let castState):
            if !castState.filePath.isEmpty {
                return (castState.filePath as NSString).deletingLastPathComponent
            }
        case .pluginView:
            break
        }
        return fallback.isEmpty ? workspacePath : fallback
    }
}
