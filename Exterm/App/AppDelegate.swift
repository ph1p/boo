import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Ghostty runtime (lazy, won't crash if fails)
        let ghosttyOK = GhosttyRuntime.shared.app != nil
        NSLog("[Exterm] Ghostty runtime: \(ghosttyOK ? "OK" : "FAILED")")

        windowController = MainWindowController()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveWorkspaces()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
