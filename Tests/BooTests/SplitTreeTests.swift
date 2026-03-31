import XCTest

@testable import Boo

final class SplitTreeTests: XCTestCase {

    func testLeafIDs() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        XCTAssertEqual(tree.leafIDs, [id])
    }

    func testSplitting() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        let (newTree, newID) = tree.splitting(leafID: id, direction: .horizontal)

        XCTAssertEqual(newTree.leafIDs.count, 2)
        XCTAssertTrue(newTree.leafIDs.contains(id))
        XCTAssertTrue(newTree.leafIDs.contains(newID))
    }

    func testSplittingNonExistentLeaf() {
        let id = UUID()
        let tree = SplitTree.leaf(id: id)
        let (newTree, _) = tree.splitting(leafID: UUID(), direction: .horizontal)
        // Should return unchanged tree
        XCTAssertEqual(newTree.leafIDs, [id])
    }

    func testRemovingLeaf() {
        let id1 = UUID()
        let tree = SplitTree.leaf(id: id1)
        let (splitTree, id2) = tree.splitting(leafID: id1, direction: .horizontal)

        let result = splitTree.removing(leafID: id2)
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

        let (t2, id3) = tree.splitting(leafID: id2, direction: .vertical)
        tree = t2

        XCTAssertEqual(tree.leafIDs.count, 3)
        XCTAssertTrue(tree.leafIDs.contains(id1))
        XCTAssertTrue(tree.leafIDs.contains(id2))
        XCTAssertTrue(tree.leafIDs.contains(id3))

        // Remove middle leaf
        if let reduced = tree.removing(leafID: id2) {
            XCTAssertEqual(reduced.leafIDs.count, 2)
            XCTAssertTrue(reduced.leafIDs.contains(id1))
            XCTAssertTrue(reduced.leafIDs.contains(id3))
        }
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
