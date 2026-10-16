import Cocoa
import XCTest

@testable import Boo

@MainActor
final class WindowManagerTests: XCTestCase {
    /// Never deallocated: freeing their ghostty surfaces at teardown can hang the
    /// suite (ghostty_surface_free joins the io thread) in some test orders.
    private static var keptAlive: [MainWindowController] = []

    func testRegisteredWindowsAllPersistSession() {
        let manager = WindowManager.shared
        let first = MainWindowController()
        // Fresh window: own workspace IDs (a restoring one would duplicate the session's).
        let second = MainWindowController(restoreSession: false)
        // Its init saves the session; it must not overwrite the file before it is registered.
        XCTAssertFalse(second.persistsSession)
        manager.register(first)
        manager.register(second)
        defer {
            manager.remove(second)
            manager.remove(first)
        }

        XCTAssertTrue(first.persistsSession)
        XCTAssertTrue(second.persistsSession)
        XCTAssertTrue(manager.primaryController === first)
        XCTAssertTrue(manager.controller(owningWorkspace: second.appState.workspaces[0].id) === second)
    }

    func testWriteSessionStoresEveryManagedWindow() throws {
        let tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-windows-\(UUID().uuidString).json"
        )
        SessionStore.overrideFilePathForTesting(tempFile)
        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
            SessionStore.overrideFilePathForTesting(nil)
        }
        let manager = WindowManager.shared
        let first = MainWindowController(restoreSession: false)
        let second = MainWindowController(restoreSession: false)
        Self.keptAlive += [first, second]
        manager.register(first)
        manager.register(second)
        defer {
            manager.remove(second)
            manager.remove(first)
        }

        manager.writeSession(from: second, sync: true)
        let snapshot = try XCTUnwrap(SessionStore.load())
        XCTAssertEqual(
            snapshot.allWindows.map { $0.workspaces.map(\.id) },
            [first, second].map { $0.appState.workspaces.map(\.id) })
        XCTAssertNotNil(snapshot.allWindows[0].frameRect)

        // A closed window drops out of the next save.
        manager.remove(second)
        manager.writeSession(from: first, sync: true)
        XCTAssertEqual(try XCTUnwrap(SessionStore.load()).allWindows.count, 1)
    }

    func testRestoringWindowAppliesSavedFrameAndSidebar() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        let frame = NSRect(
            x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 820, height: 610)
        var saved = SessionWindow(activeWorkspaceIndex: 0, workspaces: [])
        saved.frame = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
        saved.sidebarIsVisible = false
        saved.sidebarWidth = 333

        let controller = MainWindowController(restoreSession: false, restoring: saved)
        Self.keptAlive.append(controller)
        XCTAssertFalse(controller.persistsSession)
        XCTAssertEqual(controller.window?.frame, frame)
        XCTAssertEqual(controller.sidebarController.windowState.isVisible, false)
        XCTAssertEqual(controller.sidebarController.windowState.width ?? -1, 333, accuracy: 0.001)
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
