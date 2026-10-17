import Cocoa
import XCTest

@testable import Boo

@MainActor final class SplitContainerViewTests: XCTestCase {
    private final class Delegate: SplitContainerDelegate {
        var panes: [UUID: PaneView] = [:]

        func splitContainer(_ container: SplitContainerView, paneViewFor paneID: UUID) -> PaneView {
            if let existing = panes[paneID] {
                return existing
            }
            let pane = Pane(id: paneID)
            _ = pane.addTab(workingDirectory: "/tmp/\(paneID.uuidString.prefix(4))")
            let paneView = PaneView(paneID: paneID, pane: pane)
            panes[paneID] = paneView
            return paneView
        }
    }

    private func paneViews(in view: NSView) -> [PaneView] {
        var result: [PaneView] = []
        if let paneView = view as? PaneView {
            result.append(paneView)
        }
        for subview in view.subviews {
            result.append(contentsOf: paneViews(in: subview))
        }
        return result
    }

    func testUpdateReplacesOldPaneHierarchy() {
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = Delegate()
        container.splitDelegate = delegate

        let firstA = UUID()
        let firstB = UUID()
        let firstTree = SplitTree.split(
            direction: .horizontal,
            first: .leaf(id: firstA),
            second: .leaf(id: firstB),
            ratio: 0.5
        )
        container.update(tree: firstTree)

        let firstPaneViews = Set(paneViews(in: container).map(\.paneID))
        XCTAssertEqual(firstPaneViews, Set([firstA, firstB]))

        let secondA = UUID()
        let secondTree = SplitTree.leaf(id: secondA)
        container.update(tree: secondTree)

        let secondPaneViews = paneViews(in: container)
        XCTAssertEqual(secondPaneViews.count, 1)
        XCTAssertEqual(secondPaneViews.first?.paneID, secondA)
        XCTAssertFalse(secondPaneViews.contains(where: { $0.paneID == firstA || $0.paneID == firstB }))
    }

    private func makeContainer() -> (SplitContainerView, Delegate) {
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = Delegate()
        container.splitDelegate = delegate
        Self.kept.append((container, delegate))
        return (container, delegate)
    }

    /// Keep views alive for the whole run; tearing PaneViews down mid-suite
    /// can stall inside surface teardown.
    private static var kept: [(SplitContainerView, Delegate)] = []

    func testSplittingOnePaneKeepsSiblingAttachedInPlace() {
        let (container, delegate) = makeContainer()
        let a = UUID()
        let b = UUID()
        container.update(tree: .split(direction: .horizontal, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.5))
        let root = container.subviews.first
        let bParent = delegate.panes[b]?.superview

        // Split a: b must not move.
        let c = UUID()
        container.update(
            tree: .split(
                direction: .horizontal,
                first: .split(direction: .vertical, first: .leaf(id: a), second: .leaf(id: c), ratio: 0.5),
                second: .leaf(id: b), ratio: 0.5))
        XCTAssertTrue(container.subviews.first === root, "root split view is reused")
        XCTAssertTrue(delegate.panes[b]?.superview === bParent)
        XCTAssertEqual(Set(paneViews(in: container).map(\.paneID)), [a, b, c])
    }

    func testLayoutFollowsRatioAndSurvivesContainerResize() throws {
        let (container, delegate) = makeContainer()
        let a = UUID()
        let b = UUID()
        container.update(tree: .split(direction: .horizontal, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.25))
        let split = try XCTUnwrap(container.subviews.first as? ThemedSplitView)
        let available = 800 - split.dividerThickness
        XCTAssertEqual(delegate.panes[a]?.frame.width ?? 0, (available * 0.25).rounded(), accuracy: 0.5)

        var reported: SplitTree?
        container.onRatioChanged = { reported = $0 }
        container.setFrameSize(NSSize(width: 1200, height: 600))
        container.layoutSubtreeIfNeeded()
        let widened = 1200 - split.dividerThickness
        XCTAssertEqual(delegate.panes[a]?.frame.width ?? 0, (widened * 0.25).rounded(), accuracy: 0.5)
        XCTAssertNil(reported, "container resize must not write ratios back")
    }

    func testSwapReordersWithoutNewSplitView() {
        let (container, delegate) = makeContainer()
        let a = UUID()
        let b = UUID()
        let tree = SplitTree.split(direction: .horizontal, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.5)
        container.update(tree: tree)
        let root = container.subviews.first
        container.update(tree: tree.swappingLeaves(a, b))
        XCTAssertTrue(container.subviews.first === root)
        XCTAssertTrue(root?.subviews.first === delegate.panes[b])
        XCTAssertTrue(root?.subviews.last === delegate.panes[a])
    }

    func testCollapsingToLeafReplacesRoot() {
        let (container, delegate) = makeContainer()
        let a = UUID()
        let b = UUID()
        container.update(tree: .split(direction: .vertical, first: .leaf(id: a), second: .leaf(id: b), ratio: 0.5))
        container.update(tree: .leaf(id: a))
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews.first === delegate.panes[a])
        XCTAssertEqual(delegate.panes[a]?.frame, container.bounds)
    }
}
