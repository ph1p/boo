import Cocoa
import XCTest

@testable import Boo

@MainActor
final class WindowManagerTests: XCTestCase {
    /// Never deallocated: freeing their ghostty surfaces at teardown can hang the
    /// suite (ghostty_surface_free joins the io thread) in some test orders.
    private static var keptAlive: [MainWindowController] = []
    private static var keptDetached: [DetachedWorkspace] = []

    /// Fresh empty folder: the explorer would otherwise list all of $TMPDIR.
    private static func emptyFolder() -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("boo-ws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

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

    func testDetachAndAdoptMovesLivePaneViews() throws {
        let source = MainWindowController(restoreSession: false)
        let target = MainWindowController(restoreSession: false)
        Self.keptAlive += [source, target]
        source.openWorkspace(path: Self.emptyFolder())
        XCTAssertEqual(source.appState.workspaces.count, 2)
        let moving = source.appState.workspaces[1]
        let views = try XCTUnwrap(source.workspacePaneViews[moving.id])
        XCTAssertFalse(views.isEmpty)

        let detached = try XCTUnwrap(source.detachWorkspace(at: 1))
        Self.keptDetached.append(detached)
        XCTAssertNil(source.workspacePaneViews[moving.id])
        XCTAssertEqual(source.appState.workspaces.count, 1)
        XCTAssertNotNil(source.activeWorkspace)

        target.adoptWorkspace(detached, at: 0)
        XCTAssertTrue(target.appState.workspaces[0] === moving)
        XCTAssertTrue(target.activeWorkspace === moving)
        let adopted = try XCTUnwrap(target.workspacePaneViews[moving.id])
        for (id, pv) in views {
            XCTAssertTrue(adopted[id] === pv, "pane view must move, not be recreated")
            XCTAssertTrue(pv.paneDelegate === target)
            XCTAssertTrue(pv.tabDragCoordinator === target.tabDragCoordinator)
        }
        // Moving keeps the tabs alive.
        XCTAssertFalse(moving.panes.values.flatMap(\.tabs).isEmpty)
    }

    func testMovedWorkspaceIsSavedWithTargetWindow() throws {
        let tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "boo-session-move-\(UUID().uuidString).json"
        )
        SessionStore.overrideFilePathForTesting(tempFile)
        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
            SessionStore.overrideFilePathForTesting(nil)
        }
        let manager = WindowManager.shared
        let source = MainWindowController(restoreSession: false)
        let target = MainWindowController(restoreSession: false)
        Self.keptAlive += [source, target]
        manager.register(source)
        manager.register(target)
        defer {
            manager.remove(target)
            manager.remove(source)
        }
        source.openWorkspace(path: Self.emptyFolder())
        let movingID = source.appState.workspaces[1].id

        let detached = try XCTUnwrap(source.detachWorkspace(at: 1))
        Self.keptDetached.append(detached)
        target.adoptWorkspace(detached)
        manager.writeSession(from: target, sync: true)

        let windows = try XCTUnwrap(SessionStore.load()).allWindows
        XCTAssertEqual(windows.count, 2)
        XCTAssertFalse(windows[0].workspaces.map(\.id).contains(movingID))
        XCTAssertEqual(windows[1].workspaces.last?.id, movingID)
    }

    func testNewWindowAdoptingStartsWithOnlyThatWorkspace() throws {
        let source = MainWindowController(restoreSession: false)
        Self.keptAlive.append(source)
        source.openWorkspace(path: Self.emptyFolder())
        let moving = source.appState.workspaces[1]
        let detached = try XCTUnwrap(source.detachWorkspace(at: 1))
        Self.keptDetached.append(detached)

        let adopter = MainWindowController(restoreSession: false, adopting: detached)
        Self.keptAlive.append(adopter)
        XCTAssertEqual(adopter.appState.workspaces.count, 1)
        XCTAssertTrue(adopter.activeWorkspace === moving)
        XCTAssertFalse(adopter.persistsSession)
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
