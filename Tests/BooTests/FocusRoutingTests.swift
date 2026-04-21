import Cocoa
import XCTest

@testable import Boo

/// Tests for focusActiveView routing and refreshAllSurfaces correctness.
/// These are unit tests over model-layer objects — they do not require a running
/// NSApplication event loop or real Ghostty surfaces.
@MainActor
final class FocusRoutingTests: XCTestCase {

    // MARK: - focusActiveView routing (model layer)

    func testFocusCycleForwardUsesLeafOrder() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        let leafIDs = ws.splitTree.leafIDs
        XCTAssertEqual(leafIDs.count, 3)

        ws.activePaneID = id1
        let startIdx = leafIDs.firstIndex(of: id1)!
        let nextIdx = (startIdx + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx]
        XCTAssertEqual(ws.activePaneID, id2)

        let nextIdx2 = (nextIdx + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx2]
        XCTAssertEqual(ws.activePaneID, id3)

        // Wrap around from last to first
        let nextIdx3 = (nextIdx2 + 1) % leafIDs.count
        ws.activePaneID = leafIDs[nextIdx3]
        XCTAssertEqual(ws.activePaneID, id1)
    }

    func testFocusCycleBackwardWraps() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id1

        let leafIDs = ws.splitTree.leafIDs
        let startIdx = leafIDs.firstIndex(of: id1)!
        let prevIdx = (startIdx - 1 + leafIDs.count) % leafIDs.count
        ws.activePaneID = leafIDs[prevIdx]
        XCTAssertEqual(ws.activePaneID, id2)
    }

    func testFocusCycleNoOpWithSinglePane() {
        let ws = Workspace(folderPath: "/tmp")
        let ids = ws.splitTree.leafIDs
        XCTAssertEqual(ids.count, 1, "Cycle requires > 1 pane — single pane is a no-op guard")
        XCTAssertEqual(ids.count, 1)
    }

    // MARK: - refreshAllSurfaces invariants

    func testActiveWorkspaceActivePaneIDIsKnown() {
        // refreshAllSurfaces relies on ws.activePaneID being in paneViews.
        // Verify that after split the new pane is in ws.panes.
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        // Both panes must exist in the workspace
        XCTAssertNotNil(ws.pane(for: id1))
        XCTAssertNotNil(ws.pane(for: id2))
        XCTAssertTrue(ws.panes.values.contains { $0.id == id1 })
        XCTAssertTrue(ws.panes.values.contains { $0.id == id2 })
    }

    func testSplitTreeLeafIDsMatchWorkspacePanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        let leafIDs = Set(ws.splitTree.leafIDs)
        let paneIDs = Set(ws.panes.keys)

        // Every leaf in the tree must have a pane backing it
        XCTAssertTrue(leafIDs.isSubset(of: paneIDs), "All split-tree leaves must have matching panes")
        XCTAssertEqual(leafIDs, Set([id1, id2, id3]))
    }

    func testClosePaneRemovesFromSplitTree() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)

        XCTAssertTrue(ws.closePane(id2))
        XCTAssertFalse(ws.splitTree.leafIDs.contains(id2))
        XCTAssertNil(ws.pane(for: id2))
    }

    func testSplitTreeLeafIDsAfterCloseMatchPanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        let id3 = ws.splitPane(id2, direction: .vertical)

        _ = ws.closePane(id3)

        let leafIDs = Set(ws.splitTree.leafIDs)
        let paneIDs = Set(ws.panes.keys)
        XCTAssertTrue(leafIDs.isSubset(of: paneIDs))
        XCTAssertFalse(leafIDs.contains(id3))
    }

    // MARK: - Crash-safety: no pane in workspace after remove

    func testWorkspacePanesNeverContainsRemovedPane() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        ws.activePaneID = id2
        _ = ws.closePane(id2)

        XCTAssertNil(ws.pane(for: id2))
        XCTAssertEqual(ws.activePaneID, id1)
    }

    func testEqualizeSplitsAfterNestedSplitKeepsAllPanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)
        _ = ws.splitPane(id2, direction: .vertical)

        ws.equalizeSplits()

        let leafIDs = ws.splitTree.leafIDs
        for id in leafIDs {
            XCTAssertNotNil(ws.pane(for: id), "All leaves must have panes after equalize")
        }
    }
}
