import Cocoa
import XCTest

@testable import Boo

/// Tests for focusActiveView routing and refreshAllSurfaces correctness.
/// These are unit tests over model-layer objects — they do not require a running
/// NSApplication event loop or real Ghostty surfaces.
@MainActor
final class FocusRoutingTests: XCTestCase {

    // MARK: - refreshAllSurfaces invariants

    func testSplitTreeLeafIDsMatchWorkspacePanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        let id3 = ws.splitPane(id2, direction: .vertical)!

        let leafIDs = Set(ws.splitTree.leafIDs)
        let paneIDs = Set(ws.panes.keys)

        // Every leaf in the tree must have a pane backing it
        XCTAssertTrue(leafIDs.isSubset(of: paneIDs), "All split-tree leaves must have matching panes")
        XCTAssertEqual(leafIDs, Set([id1, id2, id3]))
    }

    func testSplitTreeLeafIDsAfterCloseMatchPanes() {
        let ws = Workspace(folderPath: "/tmp")
        let id1 = ws.activePaneID
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        let id3 = ws.splitPane(id2, direction: .vertical)!

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
        let id2 = ws.splitPane(id1, direction: .horizontal)!
        ws.activePaneID = id2
        _ = ws.closePane(id2)

        XCTAssertNil(ws.pane(for: id2))
        XCTAssertEqual(ws.activePaneID, id1)
    }
}
