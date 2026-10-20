import XCTest

@testable import Boo

@MainActor
final class TabGroupTests: XCTestCase {
    /// Pane with tabs in /tmp/a, /tmp/b, … and the first active.
    private func pane(_ count: Int) -> Pane {
        let pane = Pane(id: UUID())
        for i in 0..<count { _ = pane.addTab(workingDirectory: "/tmp/\(Character(UnicodeScalar(97 + i)!))") }
        pane.setActiveTab(0)
        return pane
    }

    private func dirs(_ pane: Pane) -> [String] {
        pane.tabs.map { ($0.workingDirectory as NSString).lastPathComponent }
    }

    // MARK: - Grouping

    func testDropOntoTabMakesGroupNamedAfterTarget() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 3, with: 1))
        XCTAssertEqual(dirs(p), ["a", "b", "d", "c"], "source moves next to the target")
        XCTAssertEqual(p.tabIndices(inGroup: gid), [1, 2])
        XCTAssertEqual(p.group(id: gid)?.name, "b")
        XCTAssertEqual(p.activeTab?.workingDirectory, "/tmp/a", "active tab stays the same tab")
        XCTAssertTrue(p.isFirstTabOfGroup(at: 1))
        XCTAssertFalse(p.isFirstTabOfGroup(at: 2))
    }

    func testDropOntoGroupedTabJoinsAtGroupEnd() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))
        XCTAssertEqual(p.groupTab(at: 3, with: 0), gid)
        XCTAssertEqual(dirs(p), ["a", "b", "d", "c"])
        XCTAssertEqual(p.tabIndices(inGroup: gid), [0, 1, 2])
        XCTAssertEqual(p.groups.count, 1)
    }

    func testNewGroupsTakeUnusedColors() throws {
        let p = pane(4)
        let first = try XCTUnwrap(p.groupTab(at: 1, with: 0))
        let second = try XCTUnwrap(p.groupTab(at: 3, with: 2))
        XCTAssertNotEqual(p.group(id: first)?.color, p.group(id: second)?.color)
        XCTAssertNotEqual(p.group(id: first)?.color, WorkspaceColor.none)
    }

    func testRemoveAndUngroup() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))
        p.groupTab(at: 2, with: 0)
        p.removeTabFromGroup(at: 0)
        XCTAssertEqual(dirs(p), ["b", "c", "a", "d"], "leaves past the group's end")
        XCTAssertEqual(p.tabIndices(inGroup: gid), [0, 1])
        XCTAssertEqual(p.activeTab?.workingDirectory, "/tmp/a")

        p.ungroup(gid)
        XCTAssertTrue(p.groups.isEmpty)
        XCTAssertTrue(p.tabs.allSatisfy { $0.groupID == nil })
    }

    func testGroupGoesAwayWithItsLastTab() throws {
        let p = pane(3)
        try XCTUnwrap(p.groupTab(at: 1, with: 0))
        _ = p.extractTab(at: 1)
        XCTAssertEqual(p.groups.count, 1, "one tab is still a group")
        _ = p.extractTab(at: 0)
        XCTAssertTrue(p.groups.isEmpty)
    }

    // MARK: - Moving

    func testMoveBetweenGroupTabsJoins() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))  // [a b] c d
        p.moveTab(from: 3, to: 1)  // a d b c
        XCTAssertEqual(dirs(p), ["a", "d", "b", "c"])
        XCTAssertEqual(p.tabs[1].groupID, gid)
    }

    func testMoveOutOfGroupLeaves() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))  // [a b] c d
        p.moveTab(from: 0, to: 3)  // b c d a
        XCTAssertNil(p.tabs[3].groupID)
        XCTAssertEqual(p.tabIndices(inGroup: gid), [0])
    }

    func testMoveInsideGroupStays() throws {
        let p = pane(3)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))
        p.moveTab(from: 1, to: 0)
        XCTAssertEqual(p.tabIndices(inGroup: gid), [0, 1])
    }

    func testTabFromAnotherPaneArrivesUngrouped() throws {
        let source = pane(2)
        try XCTUnwrap(source.groupTab(at: 1, with: 0))
        let tab = try XCTUnwrap(source.extractTab(at: 0))
        let target = pane(2)
        target.insertTab(tab, at: 2)
        XCTAssertNil(target.tabs[2].groupID)
        XCTAssertTrue(target.groups.isEmpty)
    }

    // MARK: - Collapse

    func testCollapseHidesAndActivatingReveals() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.groupTab(at: 2, with: 1))  // a [b c] d
        XCTAssertEqual(p.outsideTabIndex(of: gid), 3)
        p.updateGroup(gid) { $0.isCollapsed = true }
        XCTAssertTrue(p.isTabHidden(at: 1))
        XCTAssertTrue(p.isTabHidden(at: 2))
        XCTAssertFalse(p.isTabHidden(at: 3))

        p.setActiveTab(2)
        XCTAssertEqual(p.group(id: gid)?.isCollapsed, false, "a picked tab shows its group")
    }

    func testCollapseNeedsATabOutside() throws {
        let p = pane(2)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))
        XCTAssertNil(p.outsideTabIndex(of: gid))

        let q = pane(3)
        let last = try XCTUnwrap(q.groupTab(at: 2, with: 1))  // a [b c]
        XCTAssertEqual(q.outsideTabIndex(of: last), 0, "falls back to the left")
    }

    // MARK: - Persistence

    func testSessionRoundTrip() throws {
        let paneID = UUID()
        let group = TabGroup(id: UUID(), name: "api", color: .green, isCollapsed: true)
        let tab = { (gid: UUID?) in
            SessionTab(contentState: .terminal(TerminalContentState(workingDirectory: "/tmp")), groupID: gid)
        }
        let saved = SessionPane(
            id: paneID, tabs: [tab(nil), tab(group.id), tab(group.id)], activeTabIndex: 0,
            groups: [SessionTabGroup(group)])
        let decoded = try JSONDecoder().decode(SessionPane.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.groups, [SessionTabGroup(group)])

        let snapshot = SessionSnapshot(
            activeWorkspaceIndex: 0,
            workspaces: [
                SessionWorkspace(
                    id: UUID(), folderPath: "/tmp", customName: nil, color: WorkspaceColor.none.rawValue,
                    customColorRed: nil, customColorGreen: nil, customColorBlue: nil, isPinned: false,
                    splitTree: .leaf(id: paneID), panes: [decoded], activePaneID: paneID,
                    sidebarIsVisible: true, sidebarWidth: 250)
            ])
        let restored = try XCTUnwrap(SessionStore.workspaces(from: snapshot).first?.panes[paneID])
        XCTAssertEqual(restored.groups, [group])
        XCTAssertEqual(restored.tabs.map(\.groupID), [nil, group.id, group.id])
        XCTAssertEqual(restored.activeTabIndex, 0)
    }

    func testOldSessionWithoutGroupsDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","tabs":[{}],"activeTabIndex":0}"#
        let pane = try JSONDecoder().decode(SessionPane.self, from: Data(json.utf8))
        XCTAssertNil(pane.groups)
        XCTAssertNil(pane.tabs[0].groupID)
    }

    func testRestoreDropsUnknownGroupIDs() {
        let p = pane(2)
        p.restoreGroups([], memberships: [UUID(), nil])
        XCTAssertNil(p.tabs[0].groupID)
    }

    // MARK: - Tab bar

    func testSlotsHoldChipAndCollapsedTabsTakeNoRoom() throws {
        let p = pane(4)
        let pv = PaneView(paneID: p.id, pane: p)
        pv.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        let plain = pv.allTabWidths()
        let gid = try XCTUnwrap(p.groupTab(at: 2, with: 1))  // a [b c] d
        let chip = pv.groupChipWidth(at: 1)
        XCTAssertGreaterThan(chip, 0)
        XCTAssertEqual(pv.groupChipWidth(at: 2), 0)
        XCTAssertEqual(pv.allTabWidths(), [plain[0], plain[1] + chip, plain[2], plain[3]])

        let slot = try XCTUnwrap(pv.tabSlotRect(at: 1))
        XCTAssertEqual(pv.groupChipHit(at: NSPoint(x: slot.minX + 2, y: 10), tabIndex: 1), gid)
        XCTAssertNil(pv.groupChipHit(at: NSPoint(x: slot.maxX - 2, y: 10), tabIndex: 1))

        pv.toggleGroupCollapsed(gid)
        let collapsedChip = pv.groupChipWidth(at: 1)
        XCTAssertEqual(pv.allTabWidths(), [plain[0], collapsedChip, 0, plain[3]])
        XCTAssertNil(pv.visibleTabPillRect(at: 2))
        XCTAssertEqual(pv.tabIndex(at: NSPoint(x: slot.minX + 2, y: 10)), 1, "chip still clickable")
        XCTAssertFalse(pv.isOverCloseButton(point: NSPoint(x: slot.minX + collapsedChip - 2, y: 10), tabIndex: 1))
    }

    func testCollapsingTheActiveGroupMovesOff() throws {
        let p = pane(3)
        let pv = PaneView(paneID: p.id, pane: p)
        pv.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        let gid = try XCTUnwrap(p.groupTab(at: 1, with: 0))  // [a b] c, a active
        pv.toggleGroupCollapsed(gid)
        XCTAssertEqual(p.activeTabIndex, 2)
        XCTAssertEqual(p.group(id: gid)?.isCollapsed, true)
    }

    func testDropOnTabMiddleGroups() throws {
        let p = pane(3)
        let pv = PaneView(paneID: p.id, pane: p)
        pv.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        let coordinator = TabDragCoordinator()
        coordinator.sourcePaneView = pv
        let pill = try XCTUnwrap(pv.visibleTabPillRect(at: 1))
        XCTAssertEqual(
            coordinator.dropZone(in: pv, at: NSPoint(x: pill.midX, y: pill.midY)), .tabBarGroup(index: 1))
        if case .tabBarGroup = coordinator.dropZone(in: pv, at: NSPoint(x: pill.minX + 2, y: pill.midY)) {
            XCTFail("edges still insert")
        }
    }

    // MARK: - Workspace auto-color

    func testAutoColorIsStableAndUsesGitRoot() throws {
        let root = NSTemporaryDirectory() + "boo-autocolor-\(UUID().uuidString)"
        let sub = root + "/src/deep"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: false)

        XCTAssertEqual(
            WorkspaceColor.gitRoot(of: sub).map { ($0 as NSString).resolvingSymlinksInPath },
            (root as NSString).resolvingSymlinksInPath)
        XCTAssertEqual(WorkspaceColor.auto(forFolder: sub), WorkspaceColor.auto(forFolder: root))
        XCTAssertNotEqual(WorkspaceColor.auto(forFolder: root), WorkspaceColor.none)
        XCTAssertEqual(
            WorkspaceColor.auto(forFolder: "/nonexistent/x"), WorkspaceColor.auto(forFolder: "/nonexistent/x/"))
    }

    func testAutoColorKnownValue() {
        // FNV-1a is fixed: the same folder gets the same color on every launch and machine.
        let colors = Set(
            ["/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h"].map { WorkspaceColor.auto(forFolder: "/nonexistent\($0)") }
        )
        XCTAssertGreaterThan(colors.count, 2, "spreads across the palette")
    }

    // MARK: - Multi-tab grouping & group moves

    func testCreateGroupGathersScatteredTabs() throws {
        let p = pane(5)
        p.setActiveTab(3)
        let gid = try XCTUnwrap(p.createGroup(withTabsAt: [1, 4, 3]))
        XCTAssertEqual(dirs(p), ["a", "b", "d", "e", "c"], "members gather at the first pick")
        XCTAssertEqual(p.tabIndices(inGroup: gid), [1, 2, 3])
        XCTAssertEqual(p.group(id: gid)?.name, "b")
        XCTAssertEqual(p.activeTab?.workingDirectory, "/tmp/d", "active tab follows its tab")
        XCTAssertNil(p.createGroup(withTabsAt: [9]))
    }

    func testAddTabToExistingGroupJoinsAtEnd() throws {
        let p = pane(4)
        let gid = try XCTUnwrap(p.createGroup(withTabsAt: [0, 1]))
        p.addTab(at: 3, toGroup: gid)
        XCTAssertEqual(dirs(p), ["a", "b", "d", "c"])
        XCTAssertEqual(p.tabIndices(inGroup: gid), [0, 1, 2])
        XCTAssertEqual(p.groupEndIndex(forTabAt: 0), 3)
        XCTAssertNil(p.groupEndIndex(forTabAt: 3))
    }

    func testMovingTabBetweenGroupsDropsEmptiedGroup() throws {
        let p = pane(3)
        let g1 = try XCTUnwrap(p.createGroup(withTabsAt: [0]))
        let g2 = try XCTUnwrap(p.createGroup(withTabsAt: [2]))
        p.addTab(at: 0, toGroup: g2)
        XCTAssertEqual(dirs(p), ["b", "c", "a"])
        XCTAssertNil(p.group(id: g1), "group emptied by the move is pruned")
        XCTAssertEqual(p.tabIndices(inGroup: g2), [1, 2])
    }

    func testMoveGroupKeepsBlockAndSkipsOtherGroups() throws {
        let p = pane(5)
        let g1 = try XCTUnwrap(p.createGroup(withTabsAt: [0, 1]))
        let g2 = try XCTUnwrap(p.createGroup(withTabsAt: [2, 3]))
        p.moveGroup(g1, to: 5)
        XCTAssertEqual(dirs(p), ["c", "d", "e", "a", "b"])
        XCTAssertEqual(p.activeTab?.workingDirectory, "/tmp/a")
        // Dropping into the middle of another group snaps to its nearest edge.
        p.moveGroup(g1, to: 1)
        XCTAssertEqual(dirs(p), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(p.tabIndices(inGroup: g2), [2, 3])
        // Dropping onto itself is a no-op.
        p.moveGroup(g1, to: 1)
        XCTAssertEqual(dirs(p), ["a", "b", "c", "d", "e"])
    }

    func testExtractAndInsertGroupRoundTrip() throws {
        let src = pane(4)
        let gid = try XCTUnwrap(src.createGroup(withTabsAt: [1, 2]))
        src.updateGroup(gid) { $0.isCollapsed = true }
        let (group, tabs) = try XCTUnwrap(src.extractGroup(gid))
        XCTAssertEqual(dirs(src), ["a", "d"])
        XCTAssertNil(src.group(id: gid))

        let dst = pane(3)
        let other = try XCTUnwrap(dst.createGroup(withTabsAt: [0, 1]))
        dst.insertGroup(group, tabs: tabs, at: 1)
        XCTAssertEqual(dirs(dst), ["a", "b", "b", "c", "c"], "never splits an existing group")
        XCTAssertEqual(dst.tabIndices(inGroup: other), [0, 1])
        XCTAssertEqual(dst.tabIndices(inGroup: gid), [2, 3])
        XCTAssertEqual(dst.group(id: gid)?.isCollapsed, false, "arrives expanded")
        XCTAssertEqual(dst.activeTabIndex, 2)
    }
}
