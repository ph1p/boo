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
}
