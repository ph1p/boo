import XCTest

@testable import Boo

@MainActor
final class BroadcastTests: XCTestCase {
    private final class FakeReceiver: BroadcastReceiver {
        var received: [BroadcastInput] = []
        func receiveBroadcast(_ input: BroadcastInput) { received.append(input) }
    }

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: - Membership

    func testAllModeTakesEveryEligiblePaneInOrder() {
        let group = BroadcastGroup(workspaceID: UUID(), mode: .all)
        XCTAssertEqual(group.members(of: [a, b, c]) { $0 != self.b }, [a, c], "ineligible pane (agent) left out")
        XCTAssertFalse(group.isSelecting)
    }

    func testSelectedModeTogglesPanes() {
        let group = BroadcastGroup(workspaceID: UUID(), mode: .selected([a]))
        XCTAssertTrue(group.isSelecting)
        XCTAssertEqual(group.members(of: [a, b, c]) { _ in true }, [a])
        group.toggle(c)
        XCTAssertEqual(group.members(of: [a, b, c]) { _ in true }, [a, c])
        group.toggle(a)
        XCTAssertEqual(group.members(of: [a, b, c]) { _ in true }, [c])
        XCTAssertEqual(group.members(of: [a, b, c]) { $0 != self.c }, [], "picked agent pane still excluded")
    }

    func testToggleIgnoredInAllMode() {
        let group = BroadcastGroup(workspaceID: UUID(), mode: .all)
        group.toggle(a)
        XCTAssertEqual(group.mode, .all)
    }

    func testShrankToOneOnlyAfterHavingPeers() {
        let group = BroadcastGroup(workspaceID: UUID(), mode: .selected([a]))
        XCTAssertFalse(group.shrankToOne(memberCount: 1), "fresh selection starts with one pane")
        XCTAssertFalse(group.shrankToOne(memberCount: 2))
        XCTAssertFalse(group.shrankToOne(memberCount: 3))
        XCTAssertTrue(group.shrankToOne(memberCount: 1))
        XCTAssertTrue(group.shrankToOne(memberCount: 0))
    }

    // MARK: - Fan-out

    func testFanOutSkipsSourceAndNonMembers() {
        let receivers = [a: FakeReceiver(), b: FakeReceiver(), c: FakeReceiver()]
        let key = BroadcastInput.key(
            action: 1, keyCode: 0, mods: 0, consumedMods: 0, unshiftedCodepoint: 97, text: "a")
        BroadcastGroup.fanOut(key, from: a, members: [a, b]) { receivers[$0] }
        XCTAssertEqual(receivers[a]?.received, [])
        XCTAssertEqual(receivers[b]?.received, [key])
        XCTAssertEqual(receivers[c]?.received, [], "non-member gets nothing")
    }

    func testFanOutFromNonMemberSendsNothing() {
        let receivers = [a: FakeReceiver(), b: FakeReceiver()]
        BroadcastGroup.fanOut(.text("ls\n"), from: c, members: [a, b]) { receivers[$0] }
        XCTAssertTrue(receivers.values.allSatisfy { $0.received.isEmpty })
    }

    func testFanOutTextReachesAllPeers() {
        let receivers = [a: FakeReceiver(), b: FakeReceiver(), c: FakeReceiver()]
        BroadcastGroup.fanOut(.text("pasted"), from: b, members: [a, b, c]) { receivers[$0] }
        XCTAssertEqual(receivers[a]?.received, [.text("pasted")])
        XCTAssertEqual(receivers[c]?.received, [.text("pasted")])
        XCTAssertEqual(receivers[b]?.received, [])
    }

    // MARK: - Status bar

    func testSegmentLabelAndVisibility() {
        XCTAssertEqual(BroadcastSegment.label(memberCount: 1), "Broadcasting to 1 pane")
        XCTAssertEqual(BroadcastSegment.label(memberCount: 3), "Broadcasting to 3 panes")
        let segment = BroadcastSegment()
        let state = StatusBarState(
            currentDirectory: "/tmp", paneCount: 2, tabCount: 2, runningProcess: "", isRemote: false)
        XCTAssertFalse(segment.isVisible(settings: AppSettings.shared, state: state))
        XCTAssertNil(segment.accessibilitySegmentLabel(state: state))
        segment.memberCount = 2
        XCTAssertTrue(segment.isVisible(settings: AppSettings.shared, state: state))
        XCTAssertEqual(segment.accessibilitySegmentLabel(state: state), "Broadcasting to 2 panes")
    }
}
