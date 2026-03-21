import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Ghostty runtime (lazy, won't crash if fails)
        let ghosttyOK = GhosttyRuntime.shared.app != nil
        NSLog("[Exterm] Ghostty runtime: \(ghosttyOK ? "OK" : "FAILED")")

        // Enable SSH ControlMaster for connection sharing — allows the file explorer
        // to multiplex on the user's interactive SSH sessions (including password auth).
        _ = RemoteExplorer.enableControlMaster()

        windowController = MainWindowController()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)

        // Watch system appearance changes for auto-theme
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            AppSettings.shared.applySystemAppearance()
        }
        AppSettings.shared.applySystemAppearance()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SSHControlManager.shared.teardownAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
