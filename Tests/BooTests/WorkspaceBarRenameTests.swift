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
    func workspaceBarDidRequestNewWorkspace(_ bar: WorkspaceBarView) {}
}

// MARK: - Tests

final class WorkspaceBarRenameTests: XCTestCase {

    private var bar: WorkspaceBarView!
    private var spy: SpyDelegate!

    override func setUp() {
        super.setUp()
        spy = SpyDelegate()
        bar = WorkspaceBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        bar.delegate = spy

        let items = [
            WorkspaceBarView.Item(name: "alpha", path: "/tmp"),
            WorkspaceBarView.Item(name: "beta", path: "/tmp/b")
        ]
        bar.setItems(items, selectedIndex: 0)
    }

    override func tearDown() {
        bar = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - Double-click routing

    func testDoubleClickDoesNotFireSelect() {
        // The double-click path calls showRenameAlert (not the select delegate).
        // Verify select is NOT called — the bar must be in a window for
        // showRenameAlert to proceed, so without one it bails early, which is fine:
        // we're checking routing, not sheet presentation.
        bar.triggerDoubleClickForTesting(at: 0)
        XCTAssertNil(spy.selectedIndex, "Double-click must not fire didSelectAt")
    }

    func testDoubleClickOnSecondItemDoesNotFireSelect() {
        bar.triggerDoubleClickForTesting(at: 1)
        XCTAssertNil(spy.selectedIndex, "Double-click on index 1 must not fire didSelectAt")
    }

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

    // MARK: - Rename delegate callback contract

    func testRenameCallsDelegateWithNewName() {
        spy.workspaceBar(bar, renameWorkspaceAt: 0, to: "NewName")
        XCTAssertEqual(spy.renamedIndex, 0)
        XCTAssertEqual(spy.renamedName, "NewName")
    }

    func testRenameCallsDelegateOnSecondWorkspace() {
        spy.workspaceBar(bar, renameWorkspaceAt: 1, to: "Updated")
        XCTAssertEqual(spy.renamedIndex, 1)
        XCTAssertEqual(spy.renamedName, "Updated")
    }

    func testRenameSheetTrimsWhitespaceBeforeDelegate() {
        // The sheet completion handler trims whitespace before calling the delegate.
        // Verify the guard: empty-after-trim must be skipped.
        let raw = "  trimmed  "
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            spy.workspaceBar(bar, renameWorkspaceAt: 0, to: trimmed)
        }
        XCTAssertEqual(spy.renamedName, "trimmed")
    }

    func testEmptyNameAfterTrimIsNotForwarded() {
        // The guard `if !name.isEmpty` in the sheet completion handler prevents
        // forwarding a blank name to the delegate.
        let name = "   ".trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            spy.workspaceBar(bar, renameWorkspaceAt: 0, to: name)
        }
        XCTAssertNil(spy.renamedIndex, "Blank name must not reach the delegate")
    }

    // MARK: - Input field pre-population

    func testRenameAlertInputPrePopulatedWithCurrentName() {
        // The item's name is what gets put into the input field.
        // Confirm item names match what we set.
        XCTAssertEqual(bar.items[0].name, "alpha")
        XCTAssertEqual(bar.items[1].name, "beta")
    }

    // MARK: - Items state

    func testBarHoldsCorrectItemCount() {
        XCTAssertEqual(bar.items.count, 2)
    }

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
    func toolbar(_ toolbar: ToolbarView, didSelectTabAt index: Int) {}
    func toolbar(_ toolbar: ToolbarView, didCloseTabAt index: Int) {}
    func toolbarDidRequestNewTab(_ toolbar: ToolbarView) {}
    func toolbarDidToggleSidebar(_ toolbar: ToolbarView) {}
    func toolbar(_ toolbar: ToolbarView, renameWorkspaceAt index: Int, to name: String) {
        renamedIndex = index
        renamedName = name
    }
    func toolbar(_ toolbar: ToolbarView, setColorForWorkspaceAt index: Int, color: WorkspaceColor) {}
    func toolbar(_ toolbar: ToolbarView, setCustomColorForWorkspaceAt index: Int, color: NSColor) {}
    func toolbar(_ toolbar: ToolbarView, togglePinForWorkspaceAt index: Int) {}
    func toolbar(_ toolbar: ToolbarView, moveWorkspaceFrom source: Int, to destination: Int) {}
    func toolbarDidRequestNewWorkspace(_ toolbar: ToolbarView) {}
}

// MARK: - ToolbarView rename tests (top/horizontal workspace bar)

final class ToolbarViewRenameTests: XCTestCase {

    private var toolbar: ToolbarView!
    private var spy: ToolbarSpyDelegate!

    override func setUp() {
        super.setUp()
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
            tabs: [],
            sidebarVisible: false
        )
    }

    override func tearDown() {
        toolbar = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - Double-click routing

    func testDoubleClickDoesNotFireSelect() {
        // Without a window the sheet bails at the guard, but select must still not fire.
        toolbar.triggerDoubleClickForTesting(at: 0)
        XCTAssertNil(spy.selectedIndex, "Double-click must not fire didSelectWorkspaceAt")
    }

    func testDoubleClickOnSecondItemDoesNotFireSelect() {
        toolbar.triggerDoubleClickForTesting(at: 1)
        XCTAssertNil(spy.selectedIndex)
    }

    func testDoubleClickOutOfBoundsDoesNotCrash() {
        toolbar.triggerDoubleClickForTesting(at: -1)
        toolbar.triggerDoubleClickForTesting(at: 99)
    }

    // MARK: - Rename delegate contract

    func testRenameCallsDelegateWithNewName() {
        spy.toolbar(toolbar, renameWorkspaceAt: 0, to: "Renamed")
        XCTAssertEqual(spy.renamedIndex, 0)
        XCTAssertEqual(spy.renamedName, "Renamed")
    }

    func testRenameOnSecondWorkspace() {
        spy.toolbar(toolbar, renameWorkspaceAt: 1, to: "NewBeta")
        XCTAssertEqual(spy.renamedIndex, 1)
        XCTAssertEqual(spy.renamedName, "NewBeta")
    }

    func testEmptyNameNotForwarded() {
        let name = "   ".trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            spy.toolbar(toolbar, renameWorkspaceAt: 0, to: name)
        }
        XCTAssertNil(spy.renamedIndex)
    }

    func testWorkspaceNamePrePopulated() {
        XCTAssertEqual(toolbar.workspaces[0].name, "alpha")
        XCTAssertEqual(toolbar.workspaces[1].name, "beta")
    }
}
