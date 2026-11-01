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
        XCTAssertNil(settings.createWorkspaceGroup(named: "  ", with: ["a"]))
        XCTAssertNil(settings.createWorkspaceGroup(named: "Empty", with: []))
        let id = try XCTUnwrap(settings.createWorkspaceGroup(named: " Client ", with: ["a"]))
        settings.assignWorkspace(member: "b", toGroup: id)
        XCTAssertEqual(settings.workspaceGroup(forMember: "a")?.name, "Client")
        XCTAssertEqual(settings.workspaceGroup(forMember: "b")?.id, id)

        settings.renameWorkspaceGroup(id: id, to: "Work")
        settings.setWorkspaceGroupCollapsed(id: id, true)
        XCTAssertEqual(settings.workspaceGroups.first?.name, "Work")
        XCTAssertEqual(settings.workspaceGroups.first?.isCollapsed, true)

        settings.deleteWorkspaceGroup(id: id)
        XCTAssertNil(settings.workspaceGroup(forMember: "a"))
    }

    func testAssigningMovesMemberBetweenGroupsAndDropsEmptyOnes() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        let first = try XCTUnwrap(settings.createWorkspaceGroup(named: "One", with: ["a"]))
        let second = try XCTUnwrap(settings.createWorkspaceGroup(named: "Two", with: ["b"]))
        settings.assignWorkspace(member: "a", toGroup: second)
        XCTAssertEqual(settings.workspaceGroup(forMember: "a")?.id, second)
        // "One" lost its only member, so it is gone.
        XCTAssertFalse(settings.workspaceGroups.contains { $0.id == first })

        settings.assignWorkspace(member: "a", toGroup: nil)
        XCTAssertNil(settings.workspaceGroup(forMember: "a"))
        XCTAssertEqual(settings.workspaceGroup(forMember: "b")?.id, second)
    }

    /// Members are workspace ids, so two workspaces on the same folder can sit
    /// in different groups (the path-keyed version merged them).
    func testSeveralGroupsCoexist() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        let one = try XCTUnwrap(settings.createWorkspaceGroup(named: "One", with: ["ws-1", "ws-2"]))
        let two = try XCTUnwrap(settings.createWorkspaceGroup(named: "Two", with: ["ws-3", "ws-4"]))
        XCTAssertEqual(settings.workspaceGroups.count, 2)
        XCTAssertEqual(settings.workspaceGroup(forMember: "ws-2")?.id, one)
        XCTAssertEqual(settings.workspaceGroup(forMember: "ws-3")?.id, two)
    }

    func testRemoveWorkspacesFromGroups() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        let id = try XCTUnwrap(settings.createWorkspaceGroup(named: "G", with: ["a", "b"]))
        settings.removeWorkspacesFromGroups(["a"])
        XCTAssertNil(settings.workspaceGroup(forMember: "a"))
        XCTAssertEqual(settings.workspaceGroup(forMember: "b")?.id, id)
        settings.removeWorkspacesFromGroups(["b"])
        XCTAssertTrue(settings.workspaceGroups.isEmpty)
    }

    func testNextGroupNameSkipsTakenNames() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        XCTAssertEqual(settings.nextWorkspaceGroupName(), "Group")
        _ = try XCTUnwrap(settings.createWorkspaceGroup(named: settings.nextWorkspaceGroupName(), with: ["a"]))
        XCTAssertEqual(settings.nextWorkspaceGroupName(), "Group 2")
        _ = try XCTUnwrap(settings.createWorkspaceGroup(named: settings.nextWorkspaceGroupName(), with: ["b"]))
        XCTAssertEqual(settings.nextWorkspaceGroupName(), "Group 3")
    }

    func testGroupColorPersists() throws {
        let settings = AppSettings.shared
        settings.workspaceGroups = []
        let id = try XCTUnwrap(settings.createWorkspaceGroup(named: "G", with: ["a"]))
        XCTAssertEqual(settings.workspaceGroup(id: id)?.color, WorkspaceColor.none)
        settings.setWorkspaceGroupColor(id: id, .purple)
        let group = try XCTUnwrap(settings.workspaceGroup(id: id))
        XCTAssertEqual(group.color, .purple)
        XCTAssertEqual(WorkspaceGroup(dictionary: group.dictionary)?.color, .purple)

        // A custom color wins over the preset and survives the round-trip.
        settings.setWorkspaceGroupCustomColor(id: id, NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let custom = try XCTUnwrap(settings.workspaceGroup(id: id))
        XCTAssertEqual(custom.customColorHex, "#336699")
        XCTAssertEqual(WorkspaceGroup(dictionary: custom.dictionary)?.resolvedColor?.hexString, "#336699")
        // Picking a preset again drops the custom color.
        settings.setWorkspaceGroupColor(id: id, .green)
        XCTAssertNil(settings.workspaceGroup(id: id)?.customColorHex)
    }

    // MARK: - Group drop index

    func testGroupDropSnapsToGroupEdges() {
        let groups = [1..<3, 4..<7]
        // Inside the dragged group or right after it: no move.
        XCTAssertNil(WorkspaceGroupDrop.insertionIndex(raw: 2, moving: 1..<3, groups: groups, firstUnpinned: 0))
        XCTAssertNil(WorkspaceGroupDrop.insertionIndex(raw: 3, moving: 1..<3, groups: groups, firstUnpinned: 0))
        // Never splits the other group.
        XCTAssertEqual(WorkspaceGroupDrop.insertionIndex(raw: 5, moving: 1..<3, groups: groups, firstUnpinned: 0), 4)
        XCTAssertEqual(WorkspaceGroupDrop.insertionIndex(raw: 6, moving: 1..<3, groups: groups, firstUnpinned: 0), 7)
        // Stays past pinned workspaces.
        XCTAssertEqual(WorkspaceGroupDrop.insertionIndex(raw: 0, moving: 4..<7, groups: groups, firstUnpinned: 1), 1)
    }

    // MARK: - Top bar layout

    private func makeToolbar(_ items: [ToolbarView.WorkspaceItem]) -> ToolbarView {
        let bar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 1200, height: IslandMetrics.toolbarHeight))
        bar.update(workspaces: items, sidebarVisible: false)
        return bar
    }

    private func pill(
        _ name: String, group: String? = nil, collapsed: Bool = false, active: Bool = false
    )
        -> ToolbarView.WorkspaceItem
    {
        var item = ToolbarView.WorkspaceItem(name: name, isActive: active, resolvedColor: nil, isPinned: false)
        item.groupID = group
        item.groupName = group.map { "G-\($0)" }
        item.groupCollapsed = collapsed
        return item
    }

    func testToolbarGroupGetsTrayAndChip() {
        let bar = makeToolbar([pill("a", active: true), pill("b", group: "x"), pill("c", group: "x"), pill("d")])
        let layout = bar.workspaceLayout
        XCTAssertEqual(layout.groups.count, 1)
        let group = layout.groups[0]
        XCTAssertEqual(group.members, 1..<3)
        // Chip sits inside the tray, before the first member.
        XCTAssertLessThan(group.trayMinX, group.chipX)
        XCTAssertLessThan(group.chipX + group.chipWidth, layout.pillX[1])
        // Ungrouped pill after the tray starts past its edge.
        XCTAssertGreaterThan(layout.pillX[3], group.trayMaxX)
        XCTAssertTrue(layout.hidden.isEmpty)
    }

    func testToolbarCollapsedGroupHidesAllButActive() {
        let bar = makeToolbar([
            pill("a"), pill("b", group: "x", collapsed: true, active: true), pill("c", group: "x", collapsed: true)
        ])
        XCTAssertEqual(bar.workspaceLayout.hidden, [2])
        XCTAssertNotNil(bar.workspacePillRect(at: 1))
        XCTAssertNil(bar.workspacePillRect(at: 2))
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
