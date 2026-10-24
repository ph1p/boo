import XCTest

@testable import Boo

final class FileTreeBrowseStateTests: XCTestCase {

    func testStartsAttachedToTerminalCwd() {
        let state = FileTreeBrowseState()
        XCTAssertFalse(state.isDetached)
        XCTAssertEqual(state.root(terminalCwd: "/a"), "/a")
    }

    func testBrowseDetachesAndRecordsHistory() {
        var state = FileTreeBrowseState()
        state.browse(to: "/a/sub", terminalCwd: "/a")
        XCTAssertTrue(state.isDetached)
        XCTAssertEqual(state.root(terminalCwd: "/a"), "/a/sub")
        XCTAssertEqual(state.root(terminalCwd: "/elsewhere"), "/a/sub", "detached root ignores the shell")
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    func testBrowseToCurrentRootIsNoOp() {
        var state = FileTreeBrowseState()
        state.browse(to: "/a", terminalCwd: "/a")
        XCTAssertFalse(state.isDetached)
        XCTAssertFalse(state.canGoBack)
    }

    func testBackAndForward() {
        var state = FileTreeBrowseState()
        state.browse(to: "/a/one", terminalCwd: "/a")
        state.browse(to: "/a/one/two", terminalCwd: "/a")
        state.goBack(terminalCwd: "/a")
        XCTAssertEqual(state.root(terminalCwd: "/a"), "/a/one")
        state.goBack(terminalCwd: "/a")
        XCTAssertEqual(state.root(terminalCwd: "/a"), "/a")
        XCTAssertFalse(state.canGoBack)
        state.goForward(terminalCwd: "/a")
        state.goForward(terminalCwd: "/a")
        XCTAssertEqual(state.root(terminalCwd: "/a"), "/a/one/two")
        XCTAssertFalse(state.canGoForward)
    }

    func testBrowseClearsForwardHistory() {
        var state = FileTreeBrowseState()
        state.browse(to: "/a/one", terminalCwd: "/a")
        state.goBack(terminalCwd: "/a")
        state.browse(to: "/a/two", terminalCwd: "/a")
        XCTAssertFalse(state.canGoForward)
    }

    func testAttachReturnsToTerminalAndKeepsBack() {
        var state = FileTreeBrowseState()
        state.browse(to: "/x", terminalCwd: "/a")
        state.attach(terminalCwd: "/a")
        XCTAssertFalse(state.isDetached)
        XCTAssertEqual(state.root(terminalCwd: "/b"), "/b", "attached root follows the shell")
        state.goBack(terminalCwd: "/b")
        XCTAssertEqual(state.root(terminalCwd: "/b"), "/x")
    }

    func testObserveReattachesWhenShellMovesAndFollowOn() {
        var state = FileTreeBrowseState()
        state.observe(terminalCwd: "/a", follow: true)
        state.browse(to: "/x", terminalCwd: "/a")
        XCTAssertFalse(state.observe(terminalCwd: "/a", follow: true), "no shell move, stay detached")
        XCTAssertTrue(state.isDetached)
        XCTAssertTrue(state.observe(terminalCwd: "/b", follow: true))
        XCTAssertFalse(state.isDetached)
        XCTAssertEqual(state.root(terminalCwd: "/b"), "/b")
    }

    func testObserveKeepsDetachedWhenFollowOff() {
        var state = FileTreeBrowseState()
        state.observe(terminalCwd: "/a", follow: false)
        state.browse(to: "/x", terminalCwd: "/a")
        XCTAssertFalse(state.observe(terminalCwd: "/b", follow: false))
        XCTAssertEqual(state.root(terminalCwd: "/b"), "/x")
    }

    func testHistoryIsBounded() {
        var state = FileTreeBrowseState()
        for i in 0...(FileTreeBrowseState.historyLimit + 10) {
            state.browse(to: "/d\(i)", terminalCwd: "/a")
        }
        var steps = 0
        while state.canGoBack {
            state.goBack(terminalCwd: "/a")
            steps += 1
        }
        XCTAssertEqual(steps, FileTreeBrowseState.historyLimit)
    }
}
