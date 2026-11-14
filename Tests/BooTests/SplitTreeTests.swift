import XCTest

@testable import Boo

final class SplitTreeTests: XCTestCase {

    func testLeafIDs() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        XCTAssertEqual(tree.leafIDs, [id])
    }

    func testSplittingNonExistentLeaf() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        let (newTree, newID) = tree.splitting(leafID: UUID(), direction: .horizontal)
        // Should return unchanged tree and nil for the new ID
        XCTAssertEqual(newTree.leafIDs, [id])
        XCTAssertNil(newID)
    }

    func testRemovingLeaf() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        let result = splitTree.removing(leafID: id2!)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.leafIDs, [id1])
    }

    func testRemovingLastLeaf() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        let result = tree.removing(leafID: id)
        XCTAssertNil(result)
    }

    func testNestedSplits() {
        let id1 = UUID()
        var tree = SplitTree.leaf(id: id1)

        let (t1, id2) = tree.splitting(leafID: id1, direction: .horizontal)
        tree = t1

        let (t2, id3) = tree.splitting(leafID: id2!, direction: .vertical)
        tree = t2

        XCTAssertEqual(tree.leafIDs.count, 3)
        XCTAssertTrue(tree.leafIDs.contains(id1))
        XCTAssertTrue(tree.leafIDs.contains(id2!))
        XCTAssertTrue(tree.leafIDs.contains(id3!))

        // Remove middle leaf
        if let reduced = tree.removing(leafID: id2!) {
            XCTAssertEqual(reduced.leafIDs.count, 2)
            XCTAssertTrue(reduced.leafIDs.contains(id1))
            XCTAssertTrue(reduced.leafIDs.contains(id3!))
        }
    }

    func testSlotRoundTripKeepsRatioAndSide() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let inner = SplitTree.split(direction: .vertical, first: .leaf(id: b), second: .leaf(id: c), ratio: 0.3)
        let tree = SplitTree.split(direction: .horizontal, first: .leaf(id: a), second: inner, ratio: 0.7)

        for id in [a, b, c] {
            guard let slot = tree.slot(of: id), let without = tree.removing(leafID: id) else {
                return XCTFail("leaf \(id) has no slot")
            }
            XCTAssertEqual(without.inserting(leaf: id, at: slot), tree)
        }
        XCTAssertEqual(tree.slot(of: a)?.ratio, 0.7)
        XCTAssertEqual(tree.slot(of: c)?.isFirst, false)
        XCTAssertNil(SplitTree.leaf(id: a).slot(of: a))
    }

    func testSlotFallsBackToASurvivingSibling() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let inner = SplitTree.split(direction: .vertical, first: .leaf(id: b), second: .leaf(id: c), ratio: 0.5)
        let tree = SplitTree.split(direction: .horizontal, first: .leaf(id: a), second: inner, ratio: 0.7)
        guard let slot = tree.slot(of: a), let onlyC = tree.removing(leafID: a)?.removing(leafID: b) else {
            return XCTFail("setup")
        }

        // The sibling subtree lost a pane meanwhile: `a` goes beside what is left.
        XCTAssertEqual(
            onlyC.inserting(leaf: a, at: slot),
            .split(direction: .horizontal, first: .leaf(id: a), second: .leaf(id: c), ratio: 0.7))
    }

    func testEquality() {
        let id = UUID()
        let a = SplitTree.leaf(id: id)
        let b = SplitTree.leaf(id: id)
        XCTAssertEqual(a, b)

        let c = SplitTree.leaf(id: UUID())
        XCTAssertNotEqual(a, c)
    }
}
