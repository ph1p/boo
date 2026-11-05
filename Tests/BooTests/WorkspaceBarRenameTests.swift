import XCTest

@testable import Boo

// MARK: - Spy delegate

private class SpyDelegate: WorkspaceBarViewDelegate {
    var renamedIndex: Int? = nil
    var renamedName: String? = nil
    var selectedIndex: Int? = nil
    var closedIndex: Int? = nil

    func workspaceBar(_ bar: WorkspaceBarView, didSelectAt index: Int) { selectedIndex = index }
    func workspaceBar(_ bar: WorkspaceBarView, didCloseAt index: Int) { closedIndex = index }
    func workspaceBar(_ bar: WorkspaceBarView, renameWorkspaceAt index: Int, to name: String) {
        renamedIndex = index
        renamedName = name
    }
    func workspaceBar(_ bar: WorkspaceBarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {}
    func workspaceBar(_ bar: WorkspaceBarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {}
    func workspaceBar(_ bar: WorkspaceBarView, togglePinForWorkspaceAt index: Int) {}
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceFrom source: Int, to destination: Int) {}
    func workspaceBar(_ bar: WorkspaceBarView, dropWorkspaceAt index: Int, atScreenPoint point: NSPoint) {}
    func workspaceBar(_ bar: WorkspaceBarView, workspaceDragMovedOutsideTo point: NSPoint?) {}
    func workspaceBar(_ bar: WorkspaceBarView, moveWorkspaceToNewWindowAt index: Int) {}
    func workspaceBarDidRequestNewWorkspace(_ bar: WorkspaceBarView) {}
}

// MARK: - Tests

@MainActor final class WorkspaceBarRenameTests: XCTestCase {

    private var bar: WorkspaceBarView!
    private var spy: SpyDelegate!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            spy = SpyDelegate()
            // Vertical, matching the only form the app builds — the bar renders as a
            // side strip, and workspaces in the top bar are drawn by `ToolbarView`.
            bar = WorkspaceBarView(
                frame: NSRect(
                    x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 400))
            bar.isVertical = true
            bar.delegate = spy

            let items = [
                WorkspaceBarView.Item(name: "alpha", path: "/tmp"),
                WorkspaceBarView.Item(name: "beta", path: "/tmp/b")
            ]
            bar.setItems(items, selectedIndex: 0)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            bar = nil
            spy = nil
        }
        try await super.tearDown()
    }

    // MARK: - Double-click routing

    func testDoubleClickOutOfBoundsDoesNotCrash() {
        // showRenameAlert guards index validity; these must not crash
        bar.triggerDoubleClickForTesting(at: -1)
        bar.triggerDoubleClickForTesting(at: 99)
    }

    // MARK: - Single-click routing

    func testSingleClickSelectsFirstItem() {
        bar.triggerSingleClickForTesting(at: 0)
        XCTAssertEqual(spy.selectedIndex, 0)
        XCTAssertNil(spy.renamedIndex)
    }

    func testSingleClickSelectsSecondItem() {
        bar.triggerSingleClickForTesting(at: 1)
        XCTAssertEqual(spy.selectedIndex, 1)
    }

    func testSingleClickDoesNotTriggerRename() {
        bar.triggerSingleClickForTesting(at: 0)
        XCTAssertNil(spy.renamedIndex)
    }

    // MARK: - Items state

    func testSelectedIndexIsRespected() {
        bar.setItems(bar.items, selectedIndex: 1)
        XCTAssertEqual(bar.selectedIndex, 1)
    }
}

// MARK: - ToolbarView spy delegate

private class ToolbarSpyDelegate: ToolbarViewDelegate {
    var renamedIndex: Int? = nil
    var renamedName: String? = nil
    var selectedIndex: Int? = nil

    func toolbar(_ toolbar: ToolbarView, didSelectWorkspaceAt index: Int) { selectedIndex = index }
    func toolbar(_ toolbar: ToolbarView, didCloseWorkspaceAt index: Int) {}
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView) {}
    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String) {
        renamedIndex = index
        renamedName = name
    }
    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {}
    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {}
    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int) {}
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int) {}
    func toolbar(_ toolbar: ToolbarView, dropWorkspaceAt index: Int, atScreenPoint point: NSPoint) {}
    func toolbar(_ toolbar: ToolbarView, workspaceDragMovedOutsideTo point: NSPoint?) {}
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceToNewWindowAt index: Int) {}
    func toolbarDidRequestNewWorkspace(_ toolbar: ToolbarView) {}
}

// MARK: - ToolbarView rename tests (top/horizontal workspace bar)

@MainActor final class ToolbarViewRenameTests: XCTestCase {

    private var toolbar: ToolbarView!
    private var spy: ToolbarSpyDelegate!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            spy = ToolbarSpyDelegate()
            toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
            toolbar.delegate = spy

            toolbar.update(
                workspaces: [
                    ToolbarView.WorkspaceItem(
                        name: "alpha", isActive: true, resolvedColor: nil, isPinned: false),
                    ToolbarView.WorkspaceItem(
                        name: "beta", isActive: false, resolvedColor: nil, isPinned: false)
                ],
                sidebarVisible: false
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            toolbar = nil
            spy = nil
        }
        try await super.tearDown()
    }

    // MARK: - Double-click routing

    func testDoubleClickOutOfBoundsDoesNotCrash() {
        toolbar.triggerDoubleClickForTesting(at: -1)
        toolbar.triggerDoubleClickForTesting(at: 99)
    }
}
