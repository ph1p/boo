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

    /// The window whose state is written to the session file. Interim until
    /// multi-window sessions: only one window persists, the oldest open one.
    var sessionOwner: MainWindowController? { controllers.first }

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
        sessionOwner.map { $0 === controller } ?? true
    }

    func isManaged(_ controller: MainWindowController) -> Bool {
        controllers.contains { $0 === controller }
    }

    // MARK: - Lifecycle

    /// First window at launch: restores the saved session.
    @discardableResult
    func openInitialWindow() -> MainWindowController {
        installSharedHandlers()
        let controller = MainWindowController(restoreSession: true)
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
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
        return controller
    }

    func register(_ controller: MainWindowController) {
        guard !isManaged(controller) else { return }
        controller.persistsSession = controllers.isEmpty
        controllers.append(controller)
        lastActive = controller
    }

    func windowDidBecomeMain(_ controller: MainWindowController) {
        guard isManaged(controller) else { return }
        lastActive = controller
    }

    /// Called from `windowWillClose`. Hands session ownership to the next
    /// window so the session file keeps tracking an open window.
    func remove(_ controller: MainWindowController) {
        guard let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        let wasOwner = index == 0
        controllers.remove(at: index)
        if lastActive === controller { lastActive = nil }
        if wasOwner, let next = controllers.first {
            next.persistsSession = true
            next.saveSession()
        }
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
