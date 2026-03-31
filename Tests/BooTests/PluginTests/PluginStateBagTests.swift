import XCTest

@testable import Boo

// Test conformance
struct TestPluginState: PluginStateValue {
    let data: String
}

struct AnotherPluginState: PluginStateValue {
    let count: Int
}

@MainActor
final class PluginStateBagTests: XCTestCase {

    func testStoreAndRetrieve() {
        let bag = PluginStateBag()
        let state = TestPluginState(data: "hello")
        bag.set(state, for: "test-plugin")

        let retrieved = bag.get(TestPluginState.self, for: "test-plugin")
        XCTAssertEqual(retrieved?.data, "hello")
    }

    func testRetrieveWrongType() {
        let bag = PluginStateBag()
        bag.set(TestPluginState(data: "hello"), for: "test-plugin")

        let retrieved = bag.get(AnotherPluginState.self, for: "test-plugin")
        XCTAssertNil(retrieved)
    }

    func testRetrieveNonexistent() {
        let bag = PluginStateBag()
        let retrieved = bag.get(TestPluginState.self, for: "nonexistent")
        XCTAssertNil(retrieved)
    }

    func testOverwrite() {
        let bag = PluginStateBag()
        bag.set(TestPluginState(data: "first"), for: "test-plugin")
        bag.set(TestPluginState(data: "second"), for: "test-plugin")

        let retrieved = bag.get(TestPluginState.self, for: "test-plugin")
        XCTAssertEqual(retrieved?.data, "second")
    }

    func testRemove() {
        let bag = PluginStateBag()
        bag.set(TestPluginState(data: "hello"), for: "test-plugin")
        bag.remove(for: "test-plugin")

        let retrieved = bag.get(TestPluginState.self, for: "test-plugin")
        XCTAssertNil(retrieved)
    }

    func testRemoveAll() {
        let bag = PluginStateBag()
        bag.set(TestPluginState(data: "a"), for: "plugin-a")
        bag.set(TestPluginState(data: "b"), for: "plugin-b")
        XCTAssertEqual(bag.count, 2)

        bag.removeAll()
        XCTAssertEqual(bag.count, 0)
        XCTAssertNil(bag.get(TestPluginState.self, for: "plugin-a"))
    }

    func testMultiplePlugins() {
        let bag = PluginStateBag()
        bag.set(TestPluginState(data: "test"), for: "plugin-a")
        bag.set(AnotherPluginState(count: 42), for: "plugin-b")

        XCTAssertEqual(bag.get(TestPluginState.self, for: "plugin-a")?.data, "test")
        XCTAssertEqual(bag.get(AnotherPluginState.self, for: "plugin-b")?.count, 42)
        XCTAssertEqual(bag.count, 2)
    }
}
