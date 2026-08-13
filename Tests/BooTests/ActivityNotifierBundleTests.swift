import UserNotifications
import XCTest

@testable import Boo

/// Every notification path must survive running outside an `.app` bundle.
///
/// `UNUserNotificationCenter.current()` raises `NSInternalInconsistencyException`
/// ("bundleProxyForCurrentProcess is nil") when the process has no bundle proxy, which
/// aborts the entire test binary rather than failing one case. That is exactly what
/// happened in CI: a terminal bell reached `ActivityNotifier.shared`, whose initializer
/// touched `current()`, and every test after it was lost.
@MainActor
final class ActivityNotifierBundleTests: XCTestCase {
    func testTestHostIsNotAnAppBundle() {
        // Guards the premise of every assertion below: if the test host ever becomes a
        // real .app bundle, these tests stop covering the unbundled path and the
        // `currentIfBundled` nil-branch needs testing another way.
        XCTAssertNotEqual(
            Bundle.main.bundleURL.pathExtension, "app",
            "Test host is unexpectedly an .app bundle")
    }

    func testCurrentIfBundledIsNilWhenUnbundled() {
        XCTAssertNil(
            UNUserNotificationCenter.currentIfBundled,
            "Resolving the notification center outside an .app bundle must yield nil, not throw")
    }

    /// The original crash: constructing the shared notifier set a delegate on `current()`.
    func testSharedNotifierInitDoesNotTrap() {
        _ = ActivityNotifier.shared
    }

    /// The frame directly above `ActivityNotifier.shared` in the CI backtrace was a bell
    /// action delivered from ghostty, so exercise the public notify paths too.
    func testNotifyPathsDoNotTrap() {
        let notifier = ActivityNotifier.shared
        let ws = UUID()
        let pane = UUID()

        notifier.notifyBell(
            tabTitle: "tab", workspaceName: "ws", workspaceID: ws, paneID: pane, tabIndex: 0)
        notifier.notifyCommandEnded(
            tabTitle: "tab", workspaceName: "ws", exitCode: 1,
            workspaceID: ws, paneID: pane, tabIndex: 0)
        notifier.notifyDesktop(
            title: "t", body: "b", workspaceName: "ws",
            workspaceID: ws, paneID: pane, tabIndex: 0)
        notifier.requestPermission()
        notifier.refreshCachedStatus()
    }

    func testAuthorizationStatusIsDeniedWhenUnbundled() async {
        let status = await ActivityNotifier.shared.authorizationStatus()
        XCTAssertEqual(status, .denied)
    }
}
