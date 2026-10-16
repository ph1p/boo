import Cocoa

/// Owns every main window. Each window has its own `MainWindowController`
/// (own workspaces, sidebar, plugin registry); settings, themes and bookmarks
/// stay global.
///
/// App-wide entry points (unix socket, remote control, notification clicks,
/// ghostty actions without a surface) are routed through here to the active
/// window instead of whichever controller registered a closure last.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [MainWindowController] = []
    /// Most recently main window. Fallback when no Boo window is key
    /// (settings window focused, app inactive).
    private weak var lastActive: MainWindowController?
    /// Controller whose actions the app-wide main menu currently targets.
    weak var menuOwner: MainWindowController?
    private var sharedHandlersInstalled = false
    private var settingsObserver: NSObjectProtocol?
    /// Set once the app is quitting: closing windows then stay in the session.
    private(set) var isTerminating = false

    private init() {}

    /// Window that receives untargeted commands: key window first, then the
    /// last main one, then the oldest.
    var activeController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController, isManaged(key) {
            return key
        }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController, isManaged(main) {
            return main
        }
        if let last = lastActive, isManaged(last) { return last }
        return controllers.first
    }

    /// Oldest open window; runs app-wide side effects once (see `isPrimary`).
    var primaryController: MainWindowController? { controllers.first }

    /// Whether `controller` is the window that feeds app-wide projections
    /// (`AppStore.shared`). True when nothing is managed (tests).
    func isActive(_ controller: MainWindowController) -> Bool {
        activeController.map { $0 === controller } ?? true
    }

    func ownsMenu(_ controller: MainWindowController) -> Bool {
        menuOwner.map { $0 === controller } ?? true
    }

    /// Whether `controller` should run app-wide side effects that every window
    /// would otherwise repeat. Unmanaged controllers (tests) count as primary.
    func isPrimary(_ controller: MainWindowController) -> Bool {
        primaryController.map { $0 === controller } ?? true
    }

    func isManaged(_ controller: MainWindowController) -> Bool {
        controllers.contains { $0 === controller }
    }

    // MARK: - Lifecycle

    /// Windows at launch: restores every saved window (or one fresh window).
    /// The first keeps the frame autosave; the saved key window ends up key.
    @discardableResult
    func openInitialWindow() -> MainWindowController {
        installSharedHandlers()
        let snapshot = SessionStore.load()
        var saved = snapshot?.allWindows ?? []
        var keyIndex = snapshot?.resolvedKeyWindowIndex ?? 0
        // Extra windows whose folders all vanished would restore as default windows.
        if saved.count > 1 {
            let keep = saved.indices.filter { SessionStore.hasRestorableWorkspace(saved[$0]) }
            if !keep.isEmpty {
                keyIndex = keep.firstIndex(of: keyIndex) ?? 0
                saved = keep.map { saved[$0] }
            }
        }
        guard !saved.isEmpty else {
            let controller = MainWindowController(restoreSession: true)
            register(controller)
            show(controller, fullScreen: false)
            return controller
        }

        let restored = saved.enumerated().map { index, window in
            MainWindowController(restoreSession: index == 0, restoring: window)
        }
        for controller in restored { register(controller) }
        for (index, controller) in restored.enumerated() where index != keyIndex {
            show(controller, fullScreen: saved[index].isFullScreen == true)
        }
        let key = restored[keyIndex]
        show(key, fullScreen: saved[keyIndex].isFullScreen == true)
        writeSession(from: key, sync: false)
        return key
    }

    private func show(_ controller: MainWindowController, fullScreen: Bool) {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if fullScreen, controller.window?.styleMask.contains(.fullScreen) == false {
            controller.window?.toggleFullScreen(nil)
        }
    }

    /// Additional window starting with a fresh default workspace, cascaded
    /// from the current key window.
    @discardableResult
    func newWindow() -> MainWindowController {
        installSharedHandlers()
        let anchor = activeController?.window
        let controller = MainWindowController(restoreSession: false)
        if let window = controller.window, let anchor {
            window.setFrame(anchor.frame, display: false)
            let topLeft = NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        }
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        writeSession(from: controller, sync: false)
        return controller
    }

    /// New window holding a workspace dragged out of another window, its
    /// top-left corner near the drop point.
    @discardableResult
    func newWindow(
        adopting detached: DetachedWorkspace, at screenPoint: NSPoint, size: NSSize?
    ) -> MainWindowController {
        installSharedHandlers()
        let controller = MainWindowController(restoreSession: false, adopting: detached)
        if let window = controller.window {
            var frame = window.frame
            if let size { frame.size = size }
            frame.origin = NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 12 - frame.height)
            let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? window.screen
            if let screen { frame = window.constrainFrameRect(frame, to: screen) }
            window.setFrame(frame, display: false)
        }
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        writeSession(from: controller, sync: false)
        return controller
    }

    /// Frontmost managed window containing `point` (screen coordinates).
    func controller(atScreenPoint point: NSPoint, excluding excluded: MainWindowController?) -> MainWindowController? {
        // Front-to-back order of this app's windows on the active space.
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        for number in numbers {
            guard
                let controller = controllers.first(where: { $0.window?.windowNumber == number.intValue }),
                controller !== excluded,
                let window = controller.window, window.isVisible, !window.isMiniaturized,
                window.frame.contains(point)
            else { continue }
            return controller
        }
        return nil
    }

    /// Controller whose active workspace shows `paneView`.
    func controller(showing paneView: PaneView) -> MainWindowController? {
        controllers.first { $0.paneViews[paneView.paneID] === paneView }
    }

    /// Every registered window is part of the session.
    func register(_ controller: MainWindowController) {
        guard !isManaged(controller) else { return }
        controller.persistsSession = true
        controllers.append(controller)
        lastActive = controller
    }

    func windowDidBecomeMain(_ controller: MainWindowController) {
        guard isManaged(controller) else { return }
        lastActive = controller
    }

    /// Called from `windowWillClose`, which then saves the remaining windows.
    func remove(_ controller: MainWindowController) {
        guard let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        controllers.remove(at: index)
        if lastActive === controller { lastActive = nil }
    }

    // MARK: - Session

    /// Write the session file: every persisting window when `controller` is
    /// managed, only `controller` otherwise (tests, unregistered windows).
    /// Snapshots are built here on the main thread; `sync: false` encodes and
    /// writes in the background.
    func writeSession(from controller: MainWindowController, sync: Bool) {
        guard controller.persistsSession else { return }
        let windows = isManaged(controller) ? controllers.filter(\.persistsSession) : [controller]
        let keyIndex = windows.firstIndex { $0 === activeController } ?? 0
        let snapshot = SessionSnapshot(
            windows: windows.map { $0.sessionWindow() }, keyWindowIndex: keyIndex)
        if sync {
            SessionStore.save(snapshot)
        } else {
            SessionStore.saveAsync(snapshot)
        }
    }

    /// Final save on quit: flush every window's live state, then write all
    /// windows synchronously. Windows closing afterwards stay in the session.
    func saveSessionForTermination() {
        isTerminating = true
        guard let first = controllers.first else { return }
        for controller in controllers {
            controller.coordinator?.saveSidebarStateToSettings()
            controller.prepareSessionSave()
        }
        writeSession(from: first, sync: true)
    }

    /// Controller holding the workspace with `id`, if any window does.
    func controller(owningWorkspace id: UUID) -> MainWindowController? {
        controllers.first { c in c.appState.workspaces.contains { $0.id == id } }
    }

    // MARK: - Shared handlers

    /// Socket and remote-control servers hold a single closure each; install
    /// it once here and dispatch to the active window.
    func installSharedHandlers() {
        guard !sharedHandlersInstalled else { return }
        sharedHandlersInstalled = true

        BooSocketServer.shared.onControlCommand = { cmd, json, reply in
            DispatchQueue.main.async {
                WindowManager.shared.dispatchCommand(cmd: cmd, json: json, reply: reply)
            }
        }
        RemoteControlServer.shared.onCommand = { cmd, json, reply in
            DispatchQueue.main.async {
                WindowManager.shared.dispatchCommand(cmd: cmd, json: json, reply: reply)
            }
        }
        BooSocketServer.shared.onExternalSegmentsChanged = { segments in
            MainActor.assumeIsolated {
                for c in WindowManager.shared.controllers {
                    c.updateExternalStatusBarSegments(segments)
                }
            }
        }
        // App-wide reactions to settings changes; per-window chrome updates stay
        // in each controller's own observer.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { notification in
            let topicString = notification.userInfo?["topic"] as? String
            MainActor.assumeIsolated {
                let topic = topicString.flatMap(SettingsTopic.init(rawValue:))
                if let topic {
                    BooSocketServer.shared.emitSettingsChanged(topic: topic.rawValue)
                }
                if topic == nil || topic == .theme {
                    AppStore.shared.refreshTheme()
                    let theme = AppSettings.shared.theme
                    BooSocketServer.shared.emitThemeChanged(name: theme.name, isDark: theme.isDark)
                }
            }
        }
        BooSocketServer.shared.onStatusChanged = {
            MainActor.assumeIsolated {
                for c in WindowManager.shared.controllers {
                    c.bridge.reevaluateSocketProcess()
                }
            }
        }
    }

    private func dispatchCommand(
        cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void
    ) {
        guard let target = activeController else {
            reply(["ok": false, "error": "no window"])
            return
        }
        target.handleIPCCommand(cmd: cmd, json: json, reply: reply)
    }
}
