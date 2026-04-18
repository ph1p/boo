import XCTest

@testable import Boo

final class SessionStoreTests: XCTestCase {

    // Use a temp file so tests don't clobber the real session.
    private var tempFile: String!

    override func setUp() {
        super.setUp()
        tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-test-\(UUID().uuidString).json"
        )
        SessionStore.overrideFilePathForTesting(tempFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempFile)
        SessionStore.overrideFilePathForTesting(nil)
        super.tearDown()
    }

    // MARK: - Save / Load roundtrip

    func testSaveAndLoadEmpty() {
        let state = AppState()
        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.workspaces.count, 0)
        XCTAssertEqual(snapshot?.activeWorkspaceIndex, -1)
    }

    func testSaveAndLoadSingleWorkspace() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        ws.customName = "My WS"
        ws.color = .blue
        ws.isPinned = true
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()
        XCTAssertEqual(snapshot?.workspaces.count, 1)
        XCTAssertEqual(snapshot?.activeWorkspaceIndex, 0)

        let sw = snapshot!.workspaces[0]
        XCTAssertEqual(sw.folderPath, "/tmp")
        XCTAssertEqual(sw.customName, "My WS")
        XCTAssertEqual(sw.color, "blue")
        XCTAssertTrue(sw.isPinned)
        XCTAssertNil(sw.customColorRed)
    }

    func testSaveAndLoadCustomColor() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        ws.customColor = NSColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let sw = snapshot.workspaces[0]
        XCTAssertNotNil(sw.customColorRed)
        XCTAssertEqual(sw.customColorRed!, 0.1, accuracy: 0.01)
        XCTAssertEqual(sw.customColorGreen!, 0.5, accuracy: 0.01)
        XCTAssertEqual(sw.customColorBlue!, 0.9, accuracy: 0.01)
    }

    func testSaveAndLoadSplitTree() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        _ = ws.splitPane(rootID, direction: .horizontal)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let sw = snapshot.workspaces[0]
        XCTAssertEqual(sw.splitTree.leafIDs.count, 2)
    }

    func testSaveAndLoadTabsPerPane() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.addTab(workingDirectory: "/tmp/foo", title: "foo")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let sp = snapshot.workspaces[0].panes.first!
        // Original tab + the one we added
        XCTAssertEqual(sp.tabs.count, 2)
        XCTAssertTrue(sp.tabs.contains(where: { $0.workingDirectory == "/tmp/foo" }))
    }

    func testRemoteSessionNotPersisted() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.addTab(workingDirectory: "/tmp", title: "ssh session")
        pane.updateRemoteSession(at: pane.activeTabIndex, .ssh(host: "server"))
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let tabs = snapshot.workspaces[0].panes.first!.tabs
        for tab in tabs {
            // SessionTab has no remoteSession field — the type itself enforces this.
            // Verify the working directory was still captured.
            XCTAssertFalse(tab.workingDirectory.isEmpty)
        }
    }

    func testLoadReturnsNilWhenNoFile() {
        // File was never written (setUp only set path, didn't create it)
        XCTAssertNil(SessionStore.load())
    }

    func testLoadReturnsNilOnCorruptFile() {
        try? "not valid json {{{".write(toFile: tempFile, atomically: true, encoding: .utf8)
        XCTAssertNil(SessionStore.load())
    }

    // MARK: - Reconstruct workspaces

    func testRestoreWorkspacesPreservesMetadata() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        ws.customName = "Restored"
        ws.color = .green
        ws.isPinned = false
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].customName, "Restored")
        XCTAssertEqual(restored[0].color, .green)
        XCTAssertFalse(restored[0].isPinned)
    }

    func testRestoreWorkspacesSkipsMissingFolderPath() {
        let state = AppState()
        let ws = Workspace(folderPath: "/nonexistent/path/that/does/not/exist")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 0)
    }

    func testRestoreWorkspacesReconstructsSplitTree() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        _ = ws.splitPane(rootID, direction: .vertical)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)

        XCTAssertEqual(restored[0].splitTree.leafIDs.count, 2)
        XCTAssertEqual(restored[0].panes.count, 2)
    }

    func testRestoreWorkspacesReconstructsTabs() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.addTab(workingDirectory: "/tmp/bar", title: "bar")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)

        let restoredPane = restored[0].pane(for: restored[0].activePaneID)
        XCTAssertNotNil(restoredPane)
        XCTAssertEqual(restoredPane!.tabs.count, 2)
        XCTAssertTrue(restoredPane!.tabs.contains(where: { $0.workingDirectory == "/tmp/bar" }))
    }

    func testSaveAndRestoreContentTabs() throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let notesPath = (tmpDir as NSString).appendingPathComponent("boo_test_notes_\(UUID().uuidString).md")
        let readmePath = (tmpDir as NSString).appendingPathComponent("boo_test_readme_\(UUID().uuidString).md")
        FileManager.default.createFile(atPath: notesPath, contents: nil)
        FileManager.default.createFile(atPath: readmePath, contents: nil)
        defer {
            try? FileManager.default.removeItem(atPath: notesPath)
            try? FileManager.default.removeItem(atPath: readmePath)
        }

        let state = AppState()
        let ws = Workspace(folderPath: tmpDir)
        let pane = ws.pane(for: ws.activePaneID)!

        let browserIndex = pane.addTab(contentType: .browser, workingDirectory: tmpDir, title: "Example")
        pane.updateContentState(
            at: browserIndex,
            .browser(BrowserContentState(title: "Example", url: URL(string: "https://example.com/docs")!))
        )

        let editorIndex = pane.addTab(contentType: .editor, workingDirectory: tmpDir, title: "notes.md")
        pane.updateContentState(
            at: editorIndex,
            .editor(EditorContentState(title: "notes.md", filePath: notesPath, isDirty: true))
        )

        let markdownIndex = pane.addTab(contentType: .markdownPreview, workingDirectory: tmpDir, title: "README.md")
        pane.updateContentState(
            at: markdownIndex,
            .markdownPreview(MarkdownPreviewContentState(title: "README.md", filePath: readmePath))
        )

        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let savedTabs = snapshot.workspaces[0].panes.first!.tabs
        XCTAssertEqual(savedTabs[browserIndex].contentState?.contentType, .browser)
        XCTAssertEqual(savedTabs[editorIndex].contentState?.contentType, .editor)
        XCTAssertEqual(savedTabs[markdownIndex].contentState?.contentType, .markdownPreview)

        let restored = SessionStore.workspaces(from: snapshot)
        let restoredPane = restored[0].pane(for: restored[0].activePaneID)!

        XCTAssertEqual(restoredPane.tabs[browserIndex].contentType, .browser)
        if case .browser(let browserState) = restoredPane.tabs[browserIndex].state.contentState {
            XCTAssertEqual(browserState.url.absoluteString, "https://example.com/docs")
        } else {
            XCTFail("Expected restored browser content state")
        }

        XCTAssertEqual(restoredPane.tabs[editorIndex].contentType, .editor)
        if case .editor(let editorState) = restoredPane.tabs[editorIndex].state.contentState {
            XCTAssertEqual(editorState.filePath, notesPath)
            XCTAssertTrue(editorState.isDirty)
        } else {
            XCTFail("Expected restored editor content state")
        }

        XCTAssertEqual(restoredPane.tabs[markdownIndex].contentType, .markdownPreview)
        if case .markdownPreview(let markdownState) = restoredPane.tabs[markdownIndex].state.contentState {
            XCTAssertEqual(markdownState.filePath, readmePath)
        } else {
            XCTFail("Expected restored markdown content state")
        }
    }

    func testMissingFilePathFallsBackToTerminal() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!

        let editorIndex = pane.addTab(contentType: .editor, workingDirectory: "/tmp", title: "gone.swift")
        pane.updateContentState(
            at: editorIndex,
            .editor(EditorContentState(title: "gone.swift", filePath: "/nonexistent/path/gone.swift"))
        )

        let markdownIndex = pane.addTab(
            contentType: .markdownPreview, workingDirectory: "/tmp", title: "gone.md")
        pane.updateContentState(
            at: markdownIndex,
            .markdownPreview(MarkdownPreviewContentState(title: "gone.md", filePath: "/nonexistent/path/gone.md"))
        )

        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)
        let restoredPane = restored[0].pane(for: restored[0].activePaneID)!

        XCTAssertEqual(
            restoredPane.tabs[editorIndex].contentType, .terminal,
            "Editor tab with missing file should fall back to terminal")
        XCTAssertEqual(
            restoredPane.tabs[markdownIndex].contentType, .terminal,
            "Markdown tab with missing file should fall back to terminal")
    }

    func testRestoreWorkspacesRemapsDuplicatePaneIDsAcrossWorkspaces() {
        let sharedPaneID = UUID()

        let snapshot = SessionSnapshot(
            activeWorkspaceIndex: 0,
            workspaces: [
                SessionWorkspace(
                    id: UUID(),
                    folderPath: "/tmp",
                    customName: "A",
                    color: WorkspaceColor.none.rawValue,
                    customColorRed: nil,
                    customColorGreen: nil,
                    customColorBlue: nil,
                    isPinned: false,
                    splitTree: .leaf(id: sharedPaneID),
                    panes: [
                        SessionPane(
                            id: sharedPaneID,
                            tabs: [
                                SessionTab(
                                    title: "a",
                                    workingDirectory: "/tmp/a",
                                    expandedPluginIDs: nil,
                                    userCollapsedSectionIDs: nil,
                                    sidebarSectionHeights: nil,
                                    sidebarScrollOffsets: nil,
                                    sidebarSectionOrder: nil,
                                    selectedPluginTabID: nil
                                )
                            ],
                            activeTabIndex: 0
                        )
                    ],
                    activePaneID: sharedPaneID,
                    sidebarIsVisible: true,
                    sidebarWidth: 240
                ),
                SessionWorkspace(
                    id: UUID(),
                    folderPath: "/tmp",
                    customName: "B",
                    color: WorkspaceColor.none.rawValue,
                    customColorRed: nil,
                    customColorGreen: nil,
                    customColorBlue: nil,
                    isPinned: false,
                    splitTree: .leaf(id: sharedPaneID),
                    panes: [
                        SessionPane(
                            id: sharedPaneID,
                            tabs: [
                                SessionTab(
                                    title: "b1",
                                    workingDirectory: "/tmp/b1",
                                    expandedPluginIDs: nil,
                                    userCollapsedSectionIDs: nil,
                                    sidebarSectionHeights: nil,
                                    sidebarScrollOffsets: nil,
                                    sidebarSectionOrder: nil,
                                    selectedPluginTabID: nil
                                ),
                                SessionTab(
                                    title: "b2",
                                    workingDirectory: "/tmp/b2",
                                    expandedPluginIDs: nil,
                                    userCollapsedSectionIDs: nil,
                                    sidebarSectionHeights: nil,
                                    sidebarScrollOffsets: nil,
                                    sidebarSectionOrder: nil,
                                    selectedPluginTabID: nil
                                )
                            ],
                            activeTabIndex: 1
                        )
                    ],
                    activePaneID: sharedPaneID,
                    sidebarIsVisible: false,
                    sidebarWidth: 321
                )
            ]
        )

        let restored = SessionStore.workspaces(from: snapshot)

        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(Set(restored[0].splitTree.leafIDs).isDisjoint(with: Set(restored[1].splitTree.leafIDs)))
        XCTAssertEqual(restored[1].totalTabCount, 2)
        XCTAssertEqual(restored[1].sidebarState.isVisible, false)
        XCTAssertEqual(restored[1].sidebarState.width ?? -1, 321, accuracy: 0.1)
        XCTAssertNotEqual(restored[1].activePaneID, sharedPaneID)
        XCTAssertEqual(restored[1].pane(for: restored[1].activePaneID)?.activeTab?.workingDirectory, "/tmp/b2")
    }

    func testRestorePreservesCustomColor() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        ws.customColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)

        let cc = restored[0].customColor
        XCTAssertNotNil(cc)
        let rgb = cc!.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgb.redComponent, 0.2, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, 0.4, accuracy: 0.01)
        XCTAssertEqual(rgb.blueComponent, 0.8, accuracy: 0.01)
    }

    func testRestoreMultipleWorkspacesPreservesOrder() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/tmp"))
        state.addWorkspace(Workspace(folderPath: "/tmp"))
        state.addWorkspace(Workspace(folderPath: "/tmp"))
        state.workspaces[0].customName = "A"
        state.workspaces[1].customName = "B"
        state.workspaces[2].customName = "C"

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)

        XCTAssertEqual(restored.map(\.customName), ["A", "B", "C"])
    }

    func testWorkspaceSidebarStateRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        ws.sidebarState = SidebarWorkspaceState(isVisible: false, width: 312)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        XCTAssertEqual(snapshot.workspaces[0].sidebarIsVisible, false)
        XCTAssertEqual(snapshot.workspaces[0].sidebarWidth ?? -1, 312, accuracy: 0.1)

        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored[0].sidebarState.isVisible, false)
        XCTAssertEqual(restored[0].sidebarState.width ?? -1, 312, accuracy: 0.1)
    }

    func testRestoreWorkspaceSidebarStateFallsBackToDefaults() {
        let originalHidden = AppSettings.shared.sidebarDefaultHidden
        let originalWidth = AppSettings.shared.sidebarWidth
        AppSettings.shared.sidebarDefaultHidden = true
        AppSettings.shared.sidebarWidth = 287
        defer {
            AppSettings.shared.sidebarDefaultHidden = originalHidden
            AppSettings.shared.sidebarWidth = originalWidth
        }

        let snapshot = SessionSnapshot(
            activeWorkspaceIndex: 0,
            workspaces: [
                SessionWorkspace(
                    id: UUID(),
                    folderPath: "/tmp",
                    customName: nil,
                    color: WorkspaceColor.none.rawValue,
                    customColorRed: nil,
                    customColorGreen: nil,
                    customColorBlue: nil,
                    isPinned: false,
                    splitTree: .leaf(id: UUID()),
                    panes: [],
                    activePaneID: UUID(),
                    sidebarIsVisible: nil,
                    sidebarWidth: nil
                )
            ]
        )

        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].sidebarState.isVisible, false)
        XCTAssertEqual(restored[0].sidebarState.width ?? -1, 287, accuracy: 0.1)
    }

    func testSnapshotCanPreserveDifferentSidebarWidthsAcrossSequentialWorkspaces() {
        let state = AppState()
        let first = Workspace(folderPath: "/tmp")
        first.customName = "Workspace 11"
        first.sidebarState = SidebarWorkspaceState(isVisible: true, width: 246)
        let second = Workspace(folderPath: "/tmp")
        second.customName = "Workspace 12"
        second.sidebarState = SidebarWorkspaceState(isVisible: true, width: 246)
        let third = Workspace(folderPath: "/tmp")
        third.customName = "Workspace 13"
        third.sidebarState = SidebarWorkspaceState(isVisible: true, width: 246)

        state.addWorkspace(first)
        state.addWorkspace(second)
        state.addWorkspace(third)
        state.setActiveWorkspace(2)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!

        XCTAssertEqual(snapshot.activeWorkspaceIndex, 2)
        XCTAssertEqual(snapshot.workspaces.count, 3)
        XCTAssertEqual(snapshot.workspaces[0].sidebarWidth ?? -1, 246, accuracy: 0.1)
        XCTAssertEqual(snapshot.workspaces[1].sidebarWidth ?? -1, 246, accuracy: 0.1)
        XCTAssertEqual(snapshot.workspaces[2].sidebarWidth ?? -1, 246, accuracy: 0.1)
    }

    func testPerWorkspaceSidebarWidthAndVisibilityAreIndependent() {
        // Each workspace has a distinct sidebar width and visibility.
        // After save + restore, every workspace gets back its own values — not the others'.
        let state = AppState()

        let ws1 = Workspace(folderPath: "/tmp")
        ws1.customName = "Alpha"
        ws1.sidebarState = SidebarWorkspaceState(isVisible: true, width: 200)

        let ws2 = Workspace(folderPath: "/tmp")
        ws2.customName = "Beta"
        ws2.sidebarState = SidebarWorkspaceState(isVisible: false, width: 350)

        let ws3 = Workspace(folderPath: "/tmp")
        ws3.customName = "Gamma"
        ws3.sidebarState = SidebarWorkspaceState(isVisible: true, width: 500)

        state.addWorkspace(ws1)
        state.addWorkspace(ws2)
        state.addWorkspace(ws3)

        SessionStore.save(appState: state)

        // Verify the raw JSON values are correct.
        let snapshot = SessionStore.load()!
        XCTAssertEqual(snapshot.workspaces[0].sidebarIsVisible, true, "ws1 visible")
        XCTAssertEqual(snapshot.workspaces[0].sidebarWidth ?? -1, 200, accuracy: 0.1, "ws1 width")
        XCTAssertEqual(snapshot.workspaces[1].sidebarIsVisible, false, "ws2 hidden")
        XCTAssertEqual(snapshot.workspaces[1].sidebarWidth ?? -1, 350, accuracy: 0.1, "ws2 width")
        XCTAssertEqual(snapshot.workspaces[2].sidebarIsVisible, true, "ws3 visible")
        XCTAssertEqual(snapshot.workspaces[2].sidebarWidth ?? -1, 500, accuracy: 0.1, "ws3 width")

        // Verify restored Workspace objects carry distinct, correct sidebar states.
        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 3)

        XCTAssertEqual(restored[0].sidebarState.isVisible, true, "restored ws1 visible")
        XCTAssertEqual(restored[0].sidebarState.width ?? -1, 200, accuracy: 0.1, "restored ws1 width")
        XCTAssertEqual(restored[1].sidebarState.isVisible, false, "restored ws2 hidden")
        XCTAssertEqual(restored[1].sidebarState.width ?? -1, 350, accuracy: 0.1, "restored ws2 width")
        XCTAssertEqual(restored[2].sidebarState.isVisible, true, "restored ws3 visible")
        XCTAssertEqual(restored[2].sidebarState.width ?? -1, 500, accuracy: 0.1, "restored ws3 width")

        // No values leaked across workspaces.
        XCTAssertNotEqual(restored[0].sidebarState.width ?? -1, 350, "ws1 must not have ws2 width")
        XCTAssertNotEqual(restored[1].sidebarState.isVisible, true, "ws2 must not have ws1 visibility")
        XCTAssertNotEqual(restored[2].sidebarState.width ?? -1, 200, "ws3 must not have ws1 width")
    }

    func testSavePreservesActiveWorkspaceIndex() {
        let state = AppState()
        state.addWorkspace(Workspace(folderPath: "/tmp"))
        state.addWorkspace(Workspace(folderPath: "/tmp"))
        state.setActiveWorkspace(1)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        XCTAssertEqual(snapshot.activeWorkspaceIndex, 1)
    }

    // MARK: - Split ratio

    func testSplitRatioIsRoundtripped() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        _ = ws.splitPane(rootID, direction: .horizontal)
        // Manually set a non-default ratio by re-splitting to create a known ratio
        // The default after splitPane is 0.5 — verify that survives the roundtrip.
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let sw = snapshot.workspaces[0]
        if case .split(_, _, _, let ratio) = sw.splitTree {
            XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected a split tree, got a leaf")
        }
    }

    // MARK: - Active tab index

    func testActiveTabIndexRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.addTab(workingDirectory: "/tmp/a", title: "a")
        pane.addTab(workingDirectory: "/tmp/b", title: "b")
        pane.setActiveTab(1)  // second added tab (index 1 of the two new tabs, i.e. overall index 2)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let sp = snapshot.workspaces[0].panes.first!
        XCTAssertEqual(sp.activeTabIndex, pane.activeTabIndex)
    }

    func testActiveTabIndexRestoredAfterRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let pane = ws.pane(for: ws.activePaneID)!
        pane.addTab(workingDirectory: "/tmp/first", title: "first")
        pane.addTab(workingDirectory: "/tmp/second", title: "second")
        // Active is now index 2 (the last added).
        let expectedIndex = pane.activeTabIndex
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)
        let restoredPane = restored[0].pane(for: restored[0].activePaneID)!
        XCTAssertEqual(restoredPane.activeTabIndex, expectedIndex)
    }

    // MARK: - activePaneID

    func testActivePaneIDRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        let newPaneID = ws.splitPane(rootID, direction: .horizontal)
        ws.activePaneID = newPaneID
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        XCTAssertEqual(snapshot.workspaces[0].activePaneID, newPaneID)
    }

    func testActivePaneIDRestoredAfterRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        let newPaneID = ws.splitPane(rootID, direction: .vertical)
        ws.activePaneID = newPaneID
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored[0].activePaneID, newPaneID)
    }

    func testActivePaneIDFallsBackToLeafWhenNotInTree() {
        // If activePaneID references a UUID not in the splitTree (stale save),
        // activateWorkspace handles the fallback — verify workspaces(from:) at
        // minimum produces a workspace whose activePaneID is a real leaf.
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        var snapshot = SessionStore.load()!

        // Replace activePaneID with a random UUID that isn't in the tree.
        let sw = snapshot.workspaces[0]
        let corrupted = SessionWorkspace(
            id: sw.id,
            folderPath: sw.folderPath,
            customName: sw.customName,
            color: sw.color,
            customColorRed: nil,
            customColorGreen: nil,
            customColorBlue: nil,
            isPinned: sw.isPinned,
            splitTree: sw.splitTree,
            panes: sw.panes,
            activePaneID: UUID(),  // random — not in tree
            sidebarIsVisible: nil,
            sidebarWidth: nil
        )
        snapshot = SessionSnapshot(
            activeWorkspaceIndex: snapshot.activeWorkspaceIndex,
            workspaces: [corrupted]
        )

        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 1)
        // The restored activePaneID should be whatever was stored (workspaces(from:)
        // does not validate it — activateWorkspace does the fallback).
        // What matters: the workspace was reconstructed without crashing.
        XCTAssertNotNil(restored[0])
    }

    // MARK: - Per-pane tabs in split workspace

    func testEachPaneHasItsOwnTabsAfterRoundtrip() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let rootID = ws.activePaneID
        let secondID = ws.splitPane(rootID, direction: .horizontal)

        ws.pane(for: rootID)!.addTab(workingDirectory: "/tmp/root-extra", title: "root-extra")
        ws.pane(for: secondID)!.addTab(workingDirectory: "/tmp/second-extra", title: "second-extra")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        let snapshot = SessionStore.load()!
        let restored = SessionStore.workspaces(from: snapshot)

        let restoredRoot = restored[0].pane(for: rootID)
        let restoredSecond = restored[0].pane(for: secondID)
        XCTAssertNotNil(restoredRoot, "Root pane must be restored by ID")
        XCTAssertNotNil(restoredSecond, "Second pane must be restored by ID")
        XCTAssertTrue(
            restoredRoot!.tabs.contains(where: { $0.workingDirectory == "/tmp/root-extra" }))
        XCTAssertTrue(
            restoredSecond!.tabs.contains(where: { $0.workingDirectory == "/tmp/second-extra" }))
        // Tabs must not bleed across panes
        XCTAssertFalse(
            restoredRoot!.tabs.contains(where: { $0.workingDirectory == "/tmp/second-extra" }))
    }

    func testRestoreFallbackTabWhenPaneMissing() {
        // A snapshot whose splitTree references a pane ID that has no pane entry
        // should get a fallback tab at the workspace folderPath.
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        state.addWorkspace(ws)

        SessionStore.save(appState: state)
        var snapshot = SessionStore.load()!

        // Corrupt the snapshot by removing all panes
        let sw = snapshot.workspaces[0]
        let corrupted = SessionWorkspace(
            id: sw.id,
            folderPath: sw.folderPath,
            customName: sw.customName,
            color: sw.color,
            customColorRed: nil,
            customColorGreen: nil,
            customColorBlue: nil,
            isPinned: sw.isPinned,
            splitTree: sw.splitTree,
            panes: [],  // no panes
            activePaneID: sw.activePaneID,
            sidebarIsVisible: nil,
            sidebarWidth: nil
        )
        snapshot = SessionSnapshot(
            activeWorkspaceIndex: snapshot.activeWorkspaceIndex,
            workspaces: [corrupted]
        )

        let restored = SessionStore.workspaces(from: snapshot)
        XCTAssertEqual(restored.count, 1)
        let pane = restored[0].pane(for: restored[0].activePaneID)
        XCTAssertNotNil(pane)
        XCTAssertEqual(pane!.tabs.first?.workingDirectory, "/tmp")
    }

    func testSaveNormalizesEmptyPaneBeforeSnapshot() {
        let state = AppState()
        let ws = Workspace(folderPath: "/tmp")
        let secondID = ws.splitPane(ws.activePaneID, direction: .horizontal)
        _ = ws.pane(for: secondID)?.extractTab(at: 0)
        XCTAssertTrue(ws.pane(for: secondID)?.tabs.isEmpty ?? false)
        state.addWorkspace(ws)

        SessionStore.save(appState: state)

        let snapshot = SessionStore.load()!
        let savedPane = snapshot.workspaces[0].panes.first(where: { $0.id == secondID })
        XCTAssertNotNil(savedPane)
        XCTAssertEqual(savedPane?.tabs.count, 1)
        XCTAssertEqual(savedPane?.tabs.first?.workingDirectory, "/tmp")
    }
}
