import XCTest

@testable import Boo

final class NotificationBurstTrackerTests: XCTestCase {
    private let ws = UUID()
    private let pane = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func entry(_ tab: Int, _ body: String = "done") -> NotificationBurstTracker.Entry {
        .init(tabKey: ActivityNotifier.tabIdentifier(paneID: pane, tabIndex: tab), body: body)
    }

    func testSingleEventStandsAlone() {
        var tracker = NotificationBurstTracker()
        XCTAssertNil(tracker.record(workspaceID: ws, entry: entry(0), at: t0))
    }

    func testSameTabTwiceDoesNotSummarize() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        XCTAssertNil(tracker.record(workspaceID: ws, entry: entry(0), at: t0 + 1))
    }

    func testTwoTabsWithinWindowSummarize() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0, "a"), at: t0)
        let summary = tracker.record(workspaceID: ws, entry: entry(1, "b"), at: t0 + 2)
        XCTAssertEqual(summary?.entries.map(\.body), ["a", "b"])
        XCTAssertEqual(summary?.startsBurst, false)
    }

    func testEventsOutsideWindowStandAlone() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        XCTAssertNil(
            tracker.record(workspaceID: ws, entry: entry(1), at: t0 + NotificationBurstTracker.window + 1))
    }

    func testWorkspacesAreIndependent() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        XCTAssertNil(tracker.record(workspaceID: UUID(), entry: entry(1), at: t0 + 1))
    }

    func testLaterEventJoinsOpenSummaryAndSounds() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        _ = tracker.record(workspaceID: ws, entry: entry(1), at: t0 + 1)
        let later = tracker.record(workspaceID: ws, entry: entry(2), at: t0 + 60)
        XCTAssertEqual(later?.entries.count, 3)
        XCTAssertEqual(later?.startsBurst, true)
    }

    func testRepeatedTabMovesToNewestInSummary() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0, "a"), at: t0)
        _ = tracker.record(workspaceID: ws, entry: entry(1, "b"), at: t0 + 1)
        let summary = tracker.record(workspaceID: ws, entry: entry(0, "a2"), at: t0 + 2)
        XCTAssertEqual(summary?.entries.map(\.body), ["b", "a2"])
    }

    func testSummaryEmptiesOnceAllTabsSeen() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        _ = tracker.record(workspaceID: ws, entry: entry(1), at: t0 + 1)
        XCTAssertEqual(tracker.remove(tabKey: entry(0).tabKey), [])
        XCTAssertEqual(tracker.remove(tabKey: entry(1).tabKey), [ws])
        XCTAssertNil(tracker.summarized[ws])
        // Seen tabs left the burst too: the next event starts fresh.
        XCTAssertNil(tracker.record(workspaceID: ws, entry: entry(2), at: t0 + 2))
    }

    func testForgetSummaryIdentifier() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        _ = tracker.record(workspaceID: ws, entry: entry(1), at: t0 + 1)
        tracker.forget(identifier: ActivityNotifier.workspaceIdentifier(ws))
        XCTAssertNil(tracker.summarized[ws])
        XCTAssertNil(tracker.record(workspaceID: ws, entry: entry(2), at: t0 + 2))
    }

    func testForgetTabIdentifierShrinksSummary() {
        var tracker = NotificationBurstTracker()
        _ = tracker.record(workspaceID: ws, entry: entry(0), at: t0)
        _ = tracker.record(workspaceID: ws, entry: entry(1), at: t0 + 1)
        tracker.forget(identifier: entry(0).tabKey)
        XCTAssertEqual(tracker.summarized[ws]?.map(\.tabKey), [entry(1).tabKey])
    }
}

final class ActivityNotifierHelperTests: XCTestCase {
    func testIdentifiersAreStablePerTab() {
        let pane = UUID()
        XCTAssertEqual(
            ActivityNotifier.tabIdentifier(paneID: pane, tabIndex: 2),
            ActivityNotifier.tabIdentifier(paneID: pane, tabIndex: 2))
        XCTAssertNotEqual(
            ActivityNotifier.tabIdentifier(paneID: pane, tabIndex: 1),
            ActivityNotifier.tabIdentifier(paneID: pane, tabIndex: 2))
        let ws = UUID()
        XCTAssertNotEqual(ActivityNotifier.workspaceIdentifier(ws), ActivityNotifier.workspaceIdentifier(UUID()))
    }

    func testMinDuration() {
        XCTAssertTrue(ActivityNotifier.meetsMinDuration(1, minSeconds: 0))
        XCTAssertTrue(ActivityNotifier.meetsMinDuration(nil, minSeconds: 30))
        XCTAssertFalse(ActivityNotifier.meetsMinDuration(9.9, minSeconds: 10))
        XCTAssertTrue(ActivityNotifier.meetsMinDuration(10, minSeconds: 10))
    }

    func testSummaryBodyNewestFirstAndCapped() {
        XCTAssertEqual(ActivityNotifier.summaryBody(["a", "b"]), "b\na")
        XCTAssertEqual(ActivityNotifier.summaryBody(["a", "b", "c", "d", "e"]), "e\nd\nc\n+2 more")
    }

    func testNotificationSettingsDefaults() {
        let keys = ["notifyMinCommandSeconds", "notificationGroupBursts", "notificationExpiryMinutes"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertEqual(AppSettings.shared.notifyMinCommandSeconds, 10)
        XCTAssertTrue(AppSettings.shared.notificationGroupBursts)
        XCTAssertEqual(AppSettings.shared.notificationExpiryMinutes, 15)
        // 0 is a real choice ("Any" / "Never"), not "unset".
        UserDefaults.standard.set(0, forKey: "notifyMinCommandSeconds")
        XCTAssertEqual(AppSettings.shared.notifyMinCommandSeconds, 0)
    }
}
