import XCTest

@testable import Boo

@MainActor
final class ClosedItemStoreTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var destroyed: [String] = []

    private func makeStore() -> ClosedItemStore<String> {
        let store = ClosedItemStore<String>(now: { [unowned self] in self.now })
        store.destroy = { [unowned self] in self.destroyed.append($0) }
        return store
    }

    private func tab(_ paneID: UUID = UUID()) -> MainWindowController.ClosedItem {
        .tab(paneID: paneID, workingDirectory: "/tmp", index: 0)
    }

    func testPopReturnsNewestWithItsLivePayload() {
        let store = makeStore()
        store.push(fallback: tab(), live: "a", lifetime: 10)
        store.push(fallback: tab(), live: "b", lifetime: 10)

        XCTAssertEqual(store.popLast()?.live, "b")
        XCTAssertEqual(store.popLast()?.live, "a")
        XCTAssertNil(store.popLast())
        XCTAssertTrue(destroyed.isEmpty)
    }

    func testExpiryDestroysLiveAndKeepsFallback() {
        let store = makeStore()
        store.push(fallback: tab(), live: "a", lifetime: 10)

        now += 9
        store.expire()
        XCTAssertTrue(destroyed.isEmpty)

        now += 1
        store.expire()
        XCTAssertEqual(destroyed, ["a"])
        let entry = store.popLast()
        XCTAssertNotNil(entry?.fallback)
        XCTAssertNil(entry?.live)
    }

    func testExpiredEntryWithoutFallbackIsRemoved() {
        let store = makeStore()
        store.push(fallback: nil, live: "workspace", lifetime: 10)

        now += 10
        XCTAssertNil(store.popLast())
        XCTAssertEqual(destroyed, ["workspace"])
        XCTAssertTrue(store.isEmpty)
    }

    func testLifetimeZeroDestroysAtOnce() {
        let store = makeStore()
        let id = store.push(fallback: tab(), live: "a", lifetime: 0)

        XCTAssertNotNil(id)
        XCTAssertEqual(destroyed, ["a"])
        XCTAssertNil(store.entries.first?.live)
        XCTAssertNil(store.push(fallback: nil, live: "b", lifetime: 0))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testCapacityDropsOldestAndDestroysIt() {
        let store = makeStore()
        for i in 0..<(store.capacity + 2) {
            store.push(fallback: tab(), live: "\(i)", lifetime: 10)
        }

        XCTAssertEqual(store.entries.count, store.capacity)
        XCTAssertEqual(destroyed, ["0", "1"])
        XCTAssertEqual(store.entries.first?.live, "2")
    }

    func testTakeByID() {
        let store = makeStore()
        let first = store.push(fallback: tab(), live: "a", lifetime: 10)
        store.push(fallback: tab(), live: "b", lifetime: 10)

        XCTAssertEqual(first.flatMap { store.take(id: $0) }?.live, "a")
        XCTAssertNil(first.flatMap { store.take(id: $0) })
        XCTAssertEqual(store.entries.map(\.live), ["b"])
    }

    func testDropLiveKeepsFallback() {
        let store = makeStore()
        let id = store.push(fallback: tab(), live: "a", lifetime: 10)
        let bare = store.push(fallback: nil, live: "b", lifetime: 10)

        id.map { store.dropLive(id: $0) }
        bare.map { store.dropLive(id: $0) }

        XCTAssertEqual(destroyed, ["a", "b"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(store.entries.first?.live)
    }

    func testExtractAndAppendMoveEntriesWithTheirDeadline() {
        let source = makeStore()
        let target = makeStore()
        let moving = UUID()
        source.push(fallback: tab(moving), live: "moving", lifetime: 10, paneIDs: [moving])
        source.push(fallback: tab(), live: "staying", lifetime: 10, paneIDs: [UUID()])

        let taken = source.extract { $0.paneIDs.contains(moving) }
        target.append(taken)

        XCTAssertEqual(source.entries.map(\.live), ["staying"])
        XCTAssertEqual(target.entries.map(\.live), ["moving"])
        XCTAssertTrue(destroyed.isEmpty)

        now += 10
        target.expire()
        XCTAssertEqual(destroyed, ["moving"])
    }

    func testDiscardAllDestroysEveryLivePayload() {
        let store = makeStore()
        store.push(fallback: tab(), live: "a", lifetime: 10)
        store.push(fallback: tab(), lifetime: 0)
        store.push(fallback: nil, live: "b", lifetime: 10)

        store.discardAll()

        XCTAssertEqual(destroyed, ["a", "b"])
        XCTAssertTrue(store.isEmpty)
    }
}
