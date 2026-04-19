import Cocoa

public enum BooMain {
    @MainActor public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor public class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObserver: NSKeyValueObservation?

    private var windowController: MainWindowController? {
        WindowBridgeModel.shared.windowController
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Verify ~/.boo directories are usable; warn once if not.
        do {
            try BooPaths.ensureDirectories()
        } catch {
            BooAlert.showError(
                title: "Cannot Initialize Data Directory",
                message: "Failed to set up ~/.boo: \(error.localizedDescription)\n\n"
                    + "Boo will continue but settings, bookmarks, and session data cannot be saved."
            )
        }

        // Apply initial log level from settings
        BooLogger.shared.applyDebugSetting(AppSettings.shared.debugLogging)

        // Install/update shell integration scripts to ~/.boo/shell-integration/
        BooPaths.installShellIntegration()

        // Initialize Ghostty runtime (lazy, won't crash if fails)
        let ghosttyOK = GhosttyRuntime.shared.app != nil
        booLog(.info, .app, "Ghostty runtime: \(ghosttyOK ? "OK" : "FAILED")")

        // Enable SSH ControlMaster for connection sharing
        setupSSHControlMaster()

        // Start the IPC socket server for child process communication
        BooSocketServer.shared.start()

        // WindowGroup creates the NSWindow; WindowBridgeView boots MainWindowController when ready.

        // Watch system appearance changes for auto-theme
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppSettings.shared.applySystemAppearance() }
        }
        AppSettings.shared.applySystemAppearance()

        // Background update check on launch
        Task { @MainActor in
            await AutoUpdater.shared.checkForUpdates()
            UpdateWindowController.shared.showIfUpdateAvailable()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        windowController?.coordinator?.saveSidebarStateToSettings()
        windowController?.saveSession()
        SSHControlManager.shared.teardownAll()
        BooSocketServer.shared.stop()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func setupSSHControlMaster() {
        DispatchQueue.global(qos: .utility).async {
            let alreadyConfigured = RemoteExplorer.hasControlMaster()
            DispatchQueue.main.async {
                self.finishSSHControlMasterSetup(alreadyConfigured: alreadyConfigured)
            }
        }
    }

    private func finishSSHControlMasterSetup(alreadyConfigured: Bool) {
        if alreadyConfigured { return }

        if let approved = AppSettings.shared.sshControlMasterApproved {
            if approved { RemoteExplorer.enableControlMaster() }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Enable SSH Connection Sharing?"
        alert.informativeText =
            "Boo can add ControlMaster to your ~/.ssh/config so the file explorer "
            + "can reuse your SSH sessions (including password-authenticated ones). "
            + "This affects all SSH connections system-wide.\n\n"
            + "You can change this later in Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        let approved = response == .alertFirstButtonReturn
        AppSettings.shared.sshControlMasterApproved = approved
        if approved { RemoteExplorer.enableControlMaster() }
    }
}
