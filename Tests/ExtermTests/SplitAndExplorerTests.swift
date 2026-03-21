import XCTest

@testable import Exterm

final class SplitAndExplorerTests: XCTestCase {

    // MARK: - Tab Title Behavior

    func testTabTitleDefaultsToDirectoryName() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/Users/test/Documents")
        XCTAssertEqual(pane.tabs[0].title, "Documents")
    }

    func testUpdateWorkingDirectoryDoesNotOverwriteTitle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateWorkingDirectory(at: 0, "/Users/test/projects")
        // Title stays at initial value — only updateTitle changes it
        XCTAssertEqual(pane.tabs[0].title, "tmp")
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/Users/test/projects")
    }

    func testUpdateTitleSetsCustomTitle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateTitle(at: 0, "vim main.swift")
        XCTAssertEqual(pane.tabs[0].title, "vim main.swift")
    }

    func testUpdateWorkingDirectoryPreservesTerminalTitle() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        // Simulate shell setting the title
        pane.updateTitle(at: 0, "user@host: ~/projects")

        // OSC 7 directory change must NOT overwrite the terminal title
        pane.updateWorkingDirectory(at: 0, "/Users/test/projects")
        XCTAssertEqual(pane.tabs[0].title, "user@host: ~/projects")
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/Users/test/projects")
    }

    func testUpdateTitleAfterDirectoryChangeOverrides() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        XCTAssertEqual(pane.tabs[0].title, "tmp")

        // OSC 7 changes directory — title unchanged
        pane.updateWorkingDirectory(at: 0, "/Users/test")
        XCTAssertEqual(pane.tabs[0].title, "tmp")

        // OSC 2 sets terminal title
        pane.updateTitle(at: 0, "zsh")
        XCTAssertEqual(pane.tabs[0].title, "zsh")

        // Subsequent directory change does NOT overwrite title
        pane.updateWorkingDirectory(at: 0, "/var/log")
        XCTAssertEqual(pane.tabs[0].title, "zsh")
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/var/log")
    }

    func testMultipleTabsTitleIndependence() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")

        // Set terminal title only on first tab
        pane.updateTitle(at: 0, "vim")

        // Update directory on both — titles unchanged
        pane.updateWorkingDirectory(at: 0, "/c")
        pane.updateWorkingDirectory(at: 1, "/d")

        XCTAssertEqual(pane.tabs[0].title, "vim")
        XCTAssertEqual(pane.tabs[1].title, "b")
    }

    func testRestoredTabStartsWithSavedTitle() {
        let pane = Pane()
        _ = pane.addTab(id: UUID(), title: "saved-title", workingDirectory: "/saved")
        XCTAssertEqual(pane.tabs[0].title, "saved-title")

        // Directory update does NOT overwrite saved title
        pane.updateWorkingDirectory(at: 0, "/new/path")
        XCTAssertEqual(pane.tabs[0].title, "saved-title")
    }

    // MARK: - Split Pane Operations

    func testSplitInheritsCwd() {
        let ws = Workspace(folderPath: "/home/user")
        ws.pane(for: ws.activePaneID)?.updateWorkingDirectory(at: 0, "/home/user/code")
        let newID = ws.splitPane(ws.activePaneID, direction: .horizontal)
        XCTAssertEqual(ws.pane(for: newID)?.activeTab?.workingDirectory, "/home/user/code")
    }

    func testSplitPreservesOriginalPaneState() {
        let ws = Workspace(folderPath: "/tmp")
        let originalID = ws.activePaneID
        let originalPane = ws.pane(for: originalID)!
        originalPane.updateTitle(at: 0, "running vim")
        originalPane.updateWorkingDirectory(at: 0, "/projects")

        _ = ws.splitPane(originalID, direction: .vertical)

        // Original pane state should be unchanged — title set by updateTitle
        let after = ws.pane(for: originalID)!
        XCTAssertEqual(after.activeTab?.title, "running vim")
        XCTAssertEqual(after.activeTab?.workingDirectory, "/projects")
    }

    func testSplitNewPaneGetsDirectoryTitle() {
        let ws = Workspace(folderPath: "/tmp")
        ws.pane(for: ws.activePaneID)?.updateWorkingDirectory(at: 0, "/Users/test/Documents")
        let newID = ws.splitPane(ws.activePaneID, direction: .horizontal)
        let newPane = ws.pane(for: newID)!
        XCTAssertEqual(newPane.activeTab?.title, "Documents")
    }

    func testDoubleSplit() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id1, direction: .vertical)

        XCTAssertEqual(ws.panes.count, 3)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 3)
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id1))
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id2))
        XCTAssertTrue(ws.splitTree.leafIDs.contains(id3))
    }

    func testCloseMiddlePaneOfThree() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        ws.activePaneID = id2
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 2)
        // Active pane should switch to closest sibling (id3)
        XCTAssertEqual(ws.activePaneID, id3)
    }

    func testCloseNonActivePaneKeepsFocus() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id1

        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.activePaneID, id1)
    }

    // MARK: - Explorer/Directory Change

    func testDirectoryChangeUpdatesPane() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id1

        // Simulate CWD change in non-active pane — pane updates locally
        ws.pane(for: id2)?.updateWorkingDirectory(at: 0, "/other")
        XCTAssertEqual(ws.pane(for: id2)?.activeTab?.workingDirectory, "/other")
    }

    func testFocusSwitchReadsActivePaneCwd() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        // Set different directories in each pane
        ws.pane(for: id1)?.updateWorkingDirectory(at: 0, "/dir-a")
        ws.pane(for: id2)?.updateWorkingDirectory(at: 0, "/dir-b")

        // Simulate focus switch to id2
        ws.activePaneID = id2
        let cwd = ws.pane(for: id2)?.activeTab?.workingDirectory ?? ""
        XCTAssertEqual(cwd, "/dir-b")
    }

    // MARK: - SplitTree Edge Cases

    func testSplitTreeCodableRoundtrip() throws {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (nestedTree, id3) = splitTree.splitting(leafID: id2, direction: .vertical)

        let encoder = JSONEncoder()
        let data = try encoder.encode(nestedTree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded.leafIDs.count, 3)
        XCTAssertTrue(decoded.leafIDs.contains(id1))
        XCTAssertTrue(decoded.leafIDs.contains(id2))
        XCTAssertTrue(decoded.leafIDs.contains(id3))
        XCTAssertEqual(decoded, nestedTree)
    }

    func testSplitTreeSiblingLeafID() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        XCTAssertEqual(splitTree.siblingLeafID(of: id1), id2)
        XCTAssertEqual(splitTree.siblingLeafID(of: id2), id1)
    }

    func testSplitTreeSiblingLeafIDNested() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (t1, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (t2, id3) = t1.splitting(leafID: id2, direction: .vertical)

        // id2 and id3 are siblings in the inner split
        XCTAssertEqual(t2.siblingLeafID(of: id2), id3)
        XCTAssertEqual(t2.siblingLeafID(of: id3), id2)
        // id1's sibling should be the first leaf of the other subtree
        XCTAssertEqual(t2.siblingLeafID(of: id1), id2)
    }

    func testSplitTreeRemoveFromNested() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (t1, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (t2, id3) = t1.splitting(leafID: id2, direction: .vertical)

        // Remove id3 — should leave id1 | id2
        let result = t2.removing(leafID: id3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.leafIDs, [id1, id2])
    }

    func testSplitTreeLeafIDsSingleLeaf() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        XCTAssertNil(tree.siblingLeafID(of: id))
    }

    // MARK: - Workspace Equalize Splits

    func testEqualizeSplits() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        _ = ws.splitPane(id1, direction: .horizontal)

        ws.equalizeSplits()

        if case .split(_, _, _, let ratio) = ws.splitTree {
            XCTAssertEqual(ratio, 0.5)
        } else {
            XCTFail("Expected split tree after equalize")
        }
    }

    // MARK: - Tab Operations in Split Context

    func testAddTabInSplitPane() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        // Add a tab to the second pane
        ws.pane(for: id2)?.addTab(workingDirectory: "/new-tab")
        XCTAssertEqual(ws.pane(for: id2)?.tabs.count, 2)
        XCTAssertEqual(ws.pane(for: id2)?.activeTab?.workingDirectory, "/new-tab")

        // First pane unchanged
        XCTAssertEqual(ws.pane(for: id1)?.tabs.count, 1)
    }

    func testUpdateTitleOutOfBoundsIgnored() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateTitle(at: 5, "should not crash")
        pane.updateTitle(at: -1, "also safe")
        XCTAssertEqual(pane.tabs[0].title, "tmp")
    }

    func testUpdateWorkingDirectoryOutOfBoundsIgnored() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/tmp")
        pane.updateWorkingDirectory(at: 99, "/nowhere")
        XCTAssertEqual(pane.tabs[0].workingDirectory, "/tmp")
    }

    // MARK: - Rapid Title/Directory Updates

    func testRapidTitleAndDirectoryUpdates() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/start")

        // Simulate rapid sequence: shell starts, sets title, changes dir, changes title
        pane.updateTitle(at: 0, "zsh")

        pane.updateWorkingDirectory(at: 0, "/home")
        XCTAssertEqual(pane.tabs[0].title, "zsh")  // CWD does NOT overwrite title

        pane.updateTitle(at: 0, "vim file.txt")
        XCTAssertEqual(pane.tabs[0].title, "vim file.txt")

        pane.updateWorkingDirectory(at: 0, "/projects")
        XCTAssertEqual(pane.tabs[0].title, "vim file.txt")  // CWD does NOT overwrite title

        pane.updateTitle(at: 0, "zsh")
        XCTAssertEqual(pane.tabs[0].title, "zsh")
    }

    // MARK: - Pane Snapshot

    func testPaneSnapshotPreservesState() {
        let pane = Pane(id: UUID())
        _ = pane.addTab(workingDirectory: "/a")
        _ = pane.addTab(workingDirectory: "/b")
        pane.updateTitle(at: 0, "process-A")
        pane.updateTitle(at: 1, "process-B")
        pane.setActiveTab(0)

        // Simulate snapshot
        let tabSnapshots = pane.tabs.map {
            (id: $0.id, title: $0.title, workingDirectory: $0.workingDirectory)
        }

        // Restore
        let restored = Pane(id: pane.id)
        for snap in tabSnapshots {
            restored.addTab(id: snap.id, title: snap.title, workingDirectory: snap.workingDirectory)
        }
        restored.setActiveTab(0)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs[0].title, "process-A")
        XCTAssertEqual(restored.tabs[1].title, "process-B")
        XCTAssertEqual(restored.activeTabIndex, 0)

        // Directory update does NOT overwrite title
        restored.updateWorkingDirectory(at: 0, "/new")
        XCTAssertEqual(restored.tabs[0].title, "process-A")
    }

    // MARK: - Deep Split Tree

    func testFourWaySplit() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id1, direction: .vertical)
        let id4 = ws.splitPane(id2, direction: .vertical)

        XCTAssertEqual(ws.panes.count, 4)
        XCTAssertEqual(ws.splitTree.leafIDs.count, 4)

        // Close all but one
        XCTAssertTrue(ws.closePane(id4))
        XCTAssertTrue(ws.closePane(id3))
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.splitTree.leafIDs, [id1])
    }
}
