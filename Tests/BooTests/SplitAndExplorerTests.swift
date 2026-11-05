import XCTest

@testable import Boo

final class SplitAndExplorerTests: XCTestCase {

    // MARK: - Tab Title Behavior

    func testTabTitleDefaultsToDirectoryName() {
        let pane = Pane()
        _ = pane.addTab(workingDirectory: "/Users/test/Documents")
        XCTAssertEqual(pane.tabs[0].title, "Documents")
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
        _ = pane.addTab(workingDirectory: "/saved", title: "saved-title")
        XCTAssertEqual(pane.tabs[0].title, "saved-title")

        // Directory update does NOT overwrite saved title
        pane.updateWorkingDirectory(at: 0, "/new/path")
        XCTAssertEqual(pane.tabs[0].title, "saved-title")
    }

    // MARK: - Split Pane Operations

    func testSplitInheritsCwd() {
        let ws = Workspace(folderPath: "/home/user")
        ws.pane(for: ws.activePaneID)?.updateWorkingDirectory(at: 0, "/home/user/code")
        let newID = ws.splitPane(ws.activePaneID, direction: .horizontal)!
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

    func testSplitNewPaneStartsWithEmptyTitle() {
        let ws = Workspace(folderPath: "/tmp")
        ws.pane(for: ws.activePaneID)?.updateWorkingDirectory(at: 0, "/Users/test/Documents")
        let newID = ws.splitPane(ws.activePaneID, direction: .horizontal)!
        let newPane = ws.pane(for: newID)!
        XCTAssertEqual(newPane.activeTab?.title, "")
        XCTAssertEqual(newPane.activeTab?.workingDirectory, "/Users/test/Documents")
    }

    func testCloseMiddlePaneOfThree() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        let id3 = ws.splitPane(id2, direction: .vertical)!

        ws.activePaneID = id2
        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.panes.count, 2)
        // Active pane should switch to closest sibling (id3)
        XCTAssertEqual(ws.activePaneID, id3)
    }

    func testCloseNonActivePaneKeepsFocus() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        ws.activePaneID = id1

        XCTAssertTrue(ws.closePane(id2))
        XCTAssertEqual(ws.activePaneID, id1)
    }

    // MARK: - SplitTree Edge Cases

    func testSplitTreeCodableRoundtrip() throws {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (nestedTree, id3) = splitTree.splitting(leafID: id2!, direction: .vertical)

        let encoder = JSONEncoder()
        let data = try encoder.encode(nestedTree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded.leafIDs.count, 3)
        XCTAssertTrue(decoded.leafIDs.contains(id1))
        XCTAssertTrue(decoded.leafIDs.contains(id2!))
        XCTAssertTrue(decoded.leafIDs.contains(id3!))
        XCTAssertEqual(decoded, nestedTree)
    }

    func testSplitTreeSiblingLeafID() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        XCTAssertEqual(splitTree.siblingLeafID(of: id1), id2)
        XCTAssertEqual(splitTree.siblingLeafID(of: id2!), id1)
    }

    func testSplitTreeSiblingLeafIDNested() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (t1, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (t2, id3) = t1.splitting(leafID: id2!, direction: .vertical)

        // id2 and id3 are siblings in the inner split
        XCTAssertEqual(t2.siblingLeafID(of: id2!), id3)
        XCTAssertEqual(t2.siblingLeafID(of: id3!), id2)
        // id1's sibling should be the first leaf of the other subtree
        XCTAssertEqual(t2.siblingLeafID(of: id1), id2)
    }

    func testSplitTreeRemoveFromNested() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (t1, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        let (t2, id3) = t1.splitting(leafID: id2!, direction: .vertical)

        // Remove id3 — should leave id1 | id2
        let result = t2.removing(leafID: id3!)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.leafIDs, [id1, id2!])
    }

    func testSplitTreeLeafIDsSingleLeaf() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        XCTAssertNil(tree.siblingLeafID(of: id))
    }

    // MARK: - Tab Operations in Split Context

    func testAddTabInSplitPane() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!

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

    // MARK: - Deep Split Tree

    func testFourWaySplit() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        let id3 = ws.splitPane(id1, direction: .vertical)!
        let id4 = ws.splitPane(id2, direction: .vertical)!

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
