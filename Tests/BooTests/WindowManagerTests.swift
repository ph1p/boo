import Cocoa
import XCTest

@testable import Boo

@MainActor
final class WindowManagerTests: XCTestCase {
    func testOnlyFirstRegisteredWindowPersistsSession() {
        let manager = WindowManager.shared
        let first = MainWindowController()
        // Fresh window: own workspace IDs (a restoring one would duplicate the session's).
        let second = MainWindowController(restoreSession: false)
        manager.register(first)
        manager.register(second)
        defer {
            // Remove the non-owner first so removing the owner hands nothing over
            // (a handover saves the session file).
            manager.remove(second)
            manager.remove(first)
        }

        XCTAssertTrue(first.persistsSession)
        XCTAssertFalse(second.persistsSession)
        XCTAssertTrue(manager.sessionOwner === first)
        XCTAssertTrue(manager.controller(owningWorkspace: second.appState.workspaces[0].id) === second)
    }

    func testRegisterIsIdempotent() {
        let manager = WindowManager.shared
        let controller = MainWindowController()
        manager.register(controller)
        manager.register(controller)
        defer { manager.remove(controller) }

        XCTAssertEqual(manager.controllers.filter { $0 === controller }.count, 1)
    }

    func testRemoveUnmanagedControllerIsNoop() {
        let manager = WindowManager.shared
        let before = manager.controllers.count
        manager.remove(MainWindowController())
        XCTAssertEqual(manager.controllers.count, before)
    }

    func testWindowScopedNotificationsTargetOwningWindow() {
        let controller = MainWindowController()
        let other = NSWindow()
        let own = controller.window.map(ObjectIdentifier.init)

        XCTAssertTrue(controller.handlesWindowScoped(own))
        XCTAssertFalse(controller.handlesWindowScoped(ObjectIdentifier(other)))
        // No surface window and no managed windows: single-window behaviour.
        XCTAssertTrue(controller.handlesWindowScoped(nil))
    }

    func testUntargetedNotificationsGoToActiveWindowOnly() throws {
        let manager = WindowManager.shared
        let first = MainWindowController()
        let second = MainWindowController()
        manager.register(first)
        manager.register(second)
        defer {
            manager.remove(second)
            manager.remove(first)
        }
        manager.windowDidBecomeMain(second)

        // Test host has no key/main window, so the last main controller wins.
        guard NSApp.keyWindow == nil, NSApp.mainWindow == nil else {
            throw XCTSkip("a key window is present in this test host")
        }
        XCTAssertTrue(manager.activeController === second)
        XCTAssertTrue(second.handlesWindowScoped(nil))
        XCTAssertFalse(first.handlesWindowScoped(nil))
    }

    func testOnlyActiveWindowFeedsSharedProjections() throws {
        let manager = WindowManager.shared
        let first = MainWindowController()
        let second = MainWindowController(restoreSession: false)
        manager.register(first)
        manager.register(second)
        defer {
            manager.remove(second)
            manager.remove(first)
        }
        manager.windowDidBecomeMain(first)

        guard NSApp.keyWindow == nil, NSApp.mainWindow == nil else {
            throw XCTSkip("a key window is present in this test host")
        }
        XCTAssertTrue(manager.isActive(first))
        XCTAssertFalse(manager.isActive(second))
        // App-wide broadcasts come from the session owner regardless of focus.
        XCTAssertTrue(manager.isPrimary(first))
        XCTAssertFalse(manager.isPrimary(second))
    }

    func testSetupMenuItemsTakesMenuOwnership() {
        let manager = WindowManager.shared
        let first = MainWindowController()
        let second = MainWindowController(restoreSession: false)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }

        first.setupMenuItems()
        XCTAssertTrue(manager.ownsMenu(first))
        second.setupMenuItems()
        XCTAssertTrue(manager.ownsMenu(second))
        XCTAssertFalse(manager.ownsMenu(first))
    }
}
