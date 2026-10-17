import XCTest

@testable import Boo

final class SplitTreeLayoutTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    /// a | (b | c): three panes in a row.
    private var row: SplitTree {
        .split(
            direction: .horizontal, first: .leaf(id: a),
            second: .split(direction: .horizontal, first: .leaf(id: b), second: .leaf(id: c), ratio: 0.5),
            ratio: 0.5)
    }

    /// (a / b) | (c / d): a 2×2 grid, columns first.
    private var grid: SplitTree {
        .split(
            direction: .horizontal,
            first: .split(direction: .vertical, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.5),
            second: .split(direction: .vertical, first: .leaf(id: c), second: .leaf(id: d), ratio: 0.5),
            ratio: 0.5)
    }

    private func ratio(of tree: SplitTree) -> CGFloat? {
        if case .split(_, _, _, let r) = tree { return r }
        return nil
    }

    func testEqualizedGivesThreePaneRowEqualThirds() {
        let frames = row.equalized().leafFrames(in: CGRect(x: 0, y: 0, width: 900, height: 100))
        XCTAssertEqual(frames[a]?.width ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(frames[b]?.width ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(frames[c]?.width ?? 0, 300, accuracy: 0.01)
    }

    func testEqualizedCrossAxisSubtreeCountsAsOne() {
        // a | (b / c): b and c stack, so the row is two columns wide.
        let tree = SplitTree.split(
            direction: .horizontal, first: .leaf(id: a),
            second: .split(direction: .vertical, first: .leaf(id: b), second: .leaf(id: c), ratio: 0.2),
            ratio: 0.8)
        let eq = tree.equalized()
        XCTAssertEqual(ratio(of: eq) ?? 0, 0.5, accuracy: 0.001)
        guard case .split(_, _, let second, _) = eq else { return XCTFail() }
        XCTAssertEqual(ratio(of: second) ?? 0, 0.5, accuracy: 0.001)
    }

    func testLeafFramesTopLeftOrigin() {
        let frames = grid.leafFrames(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames[b], CGRect(x: 0, y: 50, width: 100, height: 50))
        XCTAssertEqual(frames[d], CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    func testNeighborInGrid() {
        XCTAssertEqual(grid.neighbor(of: a, toward: .right), c)
        XCTAssertEqual(grid.neighbor(of: a, toward: .down), b)
        XCTAssertEqual(grid.neighbor(of: d, toward: .left), b)
        XCTAssertEqual(grid.neighbor(of: d, toward: .up), c)
        XCTAssertNil(grid.neighbor(of: a, toward: .left))
        XCTAssertNil(grid.neighbor(of: a, toward: .up))
    }

    func testNeighborPrefersPaneLevelWithCentre() {
        // a (full height) | (c / d) with c taking the top 80%: c covers a's centre.
        let tree = SplitTree.split(
            direction: .horizontal, first: .leaf(id: a),
            second: .split(direction: .vertical, first: .leaf(id: c), second: .leaf(id: d), ratio: 0.8),
            ratio: 0.5)
        XCTAssertEqual(tree.neighbor(of: a, toward: .right), c)
        XCTAssertEqual(tree.neighbor(of: d, toward: .left), a)
    }

    func testResizingMovesInnermostMatchingDivider() {
        let size = CGSize(width: 1000, height: 1000)
        // b sits in the inner split (500pt wide): moving right by 50 shifts it 0.1.
        let resized = row.resizing(leafID: b, toward: .right, by: 50, in: size)
        guard case .split(_, _, let inner, let outer) = resized else { return XCTFail() }
        XCTAssertEqual(outer, 0.5, accuracy: 0.001)
        XCTAssertEqual(ratio(of: inner) ?? 0, 0.6, accuracy: 0.001)

        // a only has the outer divider.
        let outerMoved = row.resizing(leafID: a, toward: .left, by: 100, in: size)
        XCTAssertEqual(ratio(of: outerMoved) ?? 0, 0.4, accuracy: 0.001)
    }

    func testResizingWithoutMatchingAxisIsNoOp() {
        XCTAssertEqual(row.resizing(leafID: a, toward: .up, by: 50, in: CGSize(width: 1000, height: 1000)), row)
    }

    func testResizingClampsToMinimum() {
        let resized = row.resizing(
            leafID: a, toward: .left, by: 10_000, in: CGSize(width: 1000, height: 1000), minimum: 80)
        XCTAssertEqual(ratio(of: resized) ?? 0, 0.08, accuracy: 0.001)
    }

    func testSwappingLeavesKeepsShape() {
        let swapped = grid.swappingLeaves(a, d)
        XCTAssertEqual(swapped.leafIDs, [d, b, c, a])
        XCTAssertEqual(grid.swappingLeaves(a, UUID()), grid)
    }
}

final class WorkspaceZoomTests: XCTestCase {
    func testZoomShowsOnlyZoomedPane() {
        let ws = Workspace(folderPath: "/tmp")
        let first = ws.activePaneID
        _ = ws.splitPane(first, direction: .horizontal)
        ws.zoomedPaneID = first
        XCTAssertEqual(ws.displayedTree, .leaf(id: first))
    }

    func testZoomRequiresSplitAndKnownPane() {
        let ws = Workspace(folderPath: "/tmp")
        ws.zoomedPaneID = ws.activePaneID
        XCTAssertNil(ws.zoomedPaneID, "single pane has nothing to zoom")
        _ = ws.splitPane(ws.activePaneID, direction: .horizontal)
        ws.zoomedPaneID = UUID()
        XCTAssertNil(ws.zoomedPaneID)
    }

    func testZoomSurvivesRatioChangeButNotStructureChange() {
        let ws = Workspace(folderPath: "/tmp")
        let first = ws.activePaneID
        let second = ws.splitPane(first, direction: .horizontal)!
        ws.zoomedPaneID = first
        ws.equalizeSplits()
        ws.splitTree = ws.splitTree.resizing(
            leafID: first, toward: .right, by: 100, in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(ws.zoomedPaneID, first)
        _ = ws.closePane(second)
        XCTAssertNil(ws.zoomedPaneID)
    }
}

@MainActor
final class ZoomBadgeTests: XCTestCase {
    /// Pane views must outlive the suite: deallocating one can hang teardown.
    private static var kept: [PaneView] = []

    func testZoomTogglesBadgeAndClickRequestsUnzoom() {
        let pane = PaneView(paneID: UUID(), pane: Pane())
        Self.kept.append(pane)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertFalse(pane.subviews.contains { $0 is ZoomBadgeView })

        pane.isZoomed = true
        let badge = pane.subviews.compactMap { $0 as? ZoomBadgeView }.first
        XCTAssertNotNil(badge)

        var unzoomRequests = 0
        pane.onUnzoomRequested = { unzoomRequests += 1 }
        badge?.onClick?()
        XCTAssertEqual(unzoomRequests, 1)

        pane.isZoomed = false
        XCTAssertFalse(pane.subviews.contains { $0 is ZoomBadgeView })
    }
}
