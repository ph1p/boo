import Cocoa
import XCTest

@testable import Boo

@MainActor final class TabDropZoneTests: XCTestCase {
    private final class Delegate: SplitContainerDelegate {
        var panes: [UUID: PaneView] = [:]

        func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView {
            if let existing = panes[paneID] { return existing }
            let pane = Pane(id: paneID)
            _ = pane.addTab(workingDirectory: "/tmp")
            let paneView = PaneView(paneID: paneID, pane: pane)
            panes[paneID] = paneView
            return paneView
        }
    }

    /// Never deallocated: tearing PaneViews down mid-suite can stall.
    private static var kept: [AnyObject] = []

    private let coordinator = TabDragCoordinator()

    private func layout(_ tree: SplitTree) -> Delegate {
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = Delegate()
        container.splitDelegate = delegate
        container.update(tree: tree)
        Self.kept.append(contentsOf: [container, delegate, coordinator] as [AnyObject])
        return delegate
    }

    func testCornerSplitsAlongNearerEdge() throws {
        let a = UUID()
        let delegate = layout(.leaf(id: a))
        let pane = try XCTUnwrap(delegate.panes[a])
        let top = pane.tabBarHeight
        // Inside both the left and top bands, but far closer to the top.
        XCTAssertEqual(coordinator.dropZone(in: pane, at: NSPoint(x: 140, y: top + 10)), .top)
        // Inside both, closer to the left.
        XCTAssertEqual(coordinator.dropZone(in: pane, at: NSPoint(x: 10, y: top + 120)), .left)
        XCTAssertEqual(coordinator.dropZone(in: pane, at: NSPoint(x: 400, y: 350)), .center)
    }

    func testSinglePaneHasNoWorkspaceEdge() throws {
        let a = UUID()
        let delegate = layout(.leaf(id: a))
        let pane = try XCTUnwrap(delegate.panes[a])
        XCTAssertEqual(coordinator.dropZone(in: pane, at: NSPoint(x: 3, y: 300)), .left)
    }

    func testOuterBandTargetsWholeWorkspaceSide() throws {
        let a = UUID()
        let b = UUID()
        let delegate = layout(.split(direction: .horizontal, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.5))
        let left = try XCTUnwrap(delegate.panes[a])
        let right = try XCTUnwrap(delegate.panes[b])
        let w = left.bounds.width
        let h = left.bounds.height
        let top = left.tabBarHeight

        XCTAssertEqual(coordinator.dropZone(in: left, at: NSPoint(x: 4, y: 300)), .workspaceEdge(.left))
        XCTAssertEqual(coordinator.dropZone(in: left, at: NSPoint(x: 200, y: h - 4)), .workspaceEdge(.down))
        XCTAssertEqual(coordinator.dropZone(in: left, at: NSPoint(x: 200, y: top + 4)), .workspaceEdge(.up))
        // The inner edge (next to the divider) splits only this pane.
        XCTAssertEqual(coordinator.dropZone(in: left, at: NSPoint(x: w - 4, y: 300)), .right)
        XCTAssertEqual(
            coordinator.dropZone(in: right, at: NSPoint(x: right.bounds.width - 4, y: 300)), .workspaceEdge(.right))
        // Just past the band: the pane's own edge zone.
        XCTAssertEqual(coordinator.dropZone(in: left, at: NSPoint(x: 30, y: 300)), .left)
    }

    func testSplitPlacement() {
        XCTAssertNil(TabDropZone.center.splitPlacement)
        XCTAssertNil(TabDropZone.tabBarInsert(index: 0).splitPlacement)
        XCTAssertEqual(TabDropZone.top.splitPlacement?.edge, .up)
        XCTAssertEqual(TabDropZone.top.splitPlacement?.wholeWorkspace, false)
        XCTAssertEqual(TabDropZone.workspaceEdge(.right).splitPlacement?.wholeWorkspace, true)
    }
}

final class WorkspaceEdgeSplitTests: XCTestCase {
    func testLocalEdgeSplitPlacesNewPaneBefore() {
        let ws = Workspace(folderPath: "/tmp")
        let a = ws.activePaneID
        let new = ws.splitPane(a, toward: .up)!
        XCTAssertEqual(ws.splitTree.leafIDs, [new, a])
    }

    func testWholeWorkspaceEdgeWrapsRootWithEqualShare() {
        let ws = Workspace(folderPath: "/tmp")
        let a = ws.activePaneID
        let b = ws.splitPane(a, direction: .horizontal)!
        let left = ws.splitPane(b, toward: .left, wholeWorkspace: true)!
        guard case .split(.horizontal, .leaf(let first), let rest, let ratio) = ws.splitTree else {
            return XCTFail("expected new root split")
        }
        XCTAssertEqual(first, left)
        XCTAssertEqual(rest.leafIDs, [a, b])
        XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.001)

        let bottom = ws.splitPane(a, toward: .down, wholeWorkspace: true)!
        guard case .split(.vertical, _, .leaf(let last), let vRatio) = ws.splitTree else {
            return XCTFail("expected vertical root split")
        }
        XCTAssertEqual(last, bottom)
        XCTAssertEqual(vRatio, 0.5, accuracy: 0.001)
        XCTAssertNotNil(ws.pane(for: bottom))
    }
}
