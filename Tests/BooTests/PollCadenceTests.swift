import XCTest

@testable import Boo

final class PollCadenceTests: XCTestCase {

    func testRemoteMonitorPollsFastOnlyAfterRecentActivity() {
        XCTAssertEqual(RemoteSessionMonitor.pollInterval(sinceActivity: 0), RemoteSessionMonitor.fastInterval)
        XCTAssertEqual(RemoteSessionMonitor.pollInterval(sinceActivity: 59), RemoteSessionMonitor.fastInterval)
        XCTAssertEqual(
            RemoteSessionMonitor.pollInterval(sinceActivity: RemoteSessionMonitor.activeWindow),
            RemoteSessionMonitor.idleInterval)
    }

    func testContainerWatcherTicksFastOnlyForTheFocusedTab() {
        let mine = UUID()
        let other = UUID()
        XCTAssertEqual(
            ContainerCwdWatcher.tickInterval(registeredTabs: [mine], focused: mine),
            ContainerCwdWatcher.focusedInterval)
        XCTAssertEqual(
            ContainerCwdWatcher.tickInterval(registeredTabs: [mine], focused: other),
            ContainerCwdWatcher.backgroundInterval)
        XCTAssertEqual(
            ContainerCwdWatcher.tickInterval(registeredTabs: [mine], focused: nil),
            ContainerCwdWatcher.backgroundInterval)
    }
}
