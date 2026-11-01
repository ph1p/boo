import XCTest

@testable import Boo

@MainActor final class WorkspaceGroupTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            UserDefaults.standard.removeObject(forKey: "workspaceGroups")
        }
        try await super.tearDown()
    }

    // MARK: - Settings

    func testCreateAssignAndDeleteGroup() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        XCTAssertNil(settings.createWorkspaceGroup(named: "  ", with: "/tmp/a"))
        let id = try XCTUnwrap(settings.createWorkspaceGroup(named: " Client ", with: "/tmp/a"))
        settings.assignWorkspace(path: "/tmp/b", toGroup: id)
        XCTAssertEqual(settings.workspaceGroup(forPath: "/tmp/a")?.name, "Client")
        XCTAssertEqual(settings.workspaceGroup(forPath: "/tmp/b")?.id, id)

        settings.renameWorkspaceGroup(id: id, to: "Work")
        settings.setWorkspaceGroupCollapsed(id: id, true)
        XCTAssertEqual(settings.workspaceGroups.first?.name, "Work")
        XCTAssertEqual(settings.workspaceGroups.first?.isCollapsed, true)

        settings.deleteWorkspaceGroup(id: id)
        XCTAssertNil(settings.workspaceGroup(forPath: "/tmp/a"))
    }

    func testAssigningMovesPathBetweenGroupsAndDropsEmptyOnes() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        let first = try XCTUnwrap(settings.createWorkspaceGroup(named: "One", with: "/tmp/a"))
        let second = try XCTUnwrap(settings.createWorkspaceGroup(named: "Two", with: "/tmp/b"))
        settings.assignWorkspace(path: "/tmp/a", toGroup: second)
        XCTAssertEqual(settings.workspaceGroup(forPath: "/tmp/a")?.id, second)
        // "One" lost its only member, so it is gone.
        XCTAssertFalse(settings.workspaceGroups.contains { $0.id == first })

        settings.assignWorkspace(path: "/tmp/a", toGroup: nil)
        XCTAssertNil(settings.workspaceGroup(forPath: "/tmp/a"))
        XCTAssertEqual(settings.workspaceGroup(forPath: "/tmp/b")?.id, second)
    }

    // MARK: - Bar layout

    private func makeBar(_ items: [WorkspaceBarView.Item], selected: Int) -> WorkspaceBarView {
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 600))
        bar.isVertical = true
        bar.setItems(items, selectedIndex: selected)
        return bar
    }

    private func item(_ name: String, group: String? = nil, collapsed: Bool = false) -> WorkspaceBarView.Item {
        WorkspaceBarView.Item(
            name: name, path: "/tmp/\(name)", groupID: group, groupName: group.map { "G-\($0)" },
            groupCollapsed: collapsed)
    }

    func testUngroupedLayoutIsUnchanged() {
        let bar = makeBar([item("a"), item("b"), item("c")], selected: 0)
        let step = WorkspaceBarView.verticalItemSize + WorkspaceBarView.verticalItemGap
        XCTAssertEqual(bar.verticalItemRect(at: 2).minY, 2 * step)
        XCTAssertEqual(bar.verticalContentHeight, 3 * step)
        XCTAssertTrue(bar.groupHeaders.isEmpty)
    }

    func testExpandedGroupGetsHeaderRow() {
        let bar = makeBar([item("a"), item("b", group: "x"), item("c", group: "x"), item("d")], selected: 0)
        XCTAssertEqual(bar.groupHeaders.count, 1)
        let header = bar.groupHeaders[0]
        XCTAssertEqual(header.members, 1..<3)
        XCTAssertFalse(header.collapsed)
        XCTAssertGreaterThanOrEqual(bar.verticalItemRect(at: 1).minY, bar.groupHeaderRect(header).maxY)
        XCTAssertTrue(bar.hiddenRows.isEmpty)
    }

    func testCollapsedGroupHidesMembersExceptSelected() {
        let items = [item("a"), item("b", group: "x", collapsed: true), item("c", group: "x", collapsed: true)]
        let collapsedNoneSelected = makeBar(items, selected: 0)
        XCTAssertEqual(collapsedNoneSelected.hiddenRows, [1, 2])
        // One row for "a", one folder pill for the group.
        let step = WorkspaceBarView.verticalItemSize + WorkspaceBarView.verticalItemGap
        XCTAssertEqual(collapsedNoneSelected.verticalContentHeight, 2 * step)

        let selectedInside = makeBar(items, selected: 2)
        XCTAssertEqual(selectedInside.hiddenRows, [1])
    }
}
