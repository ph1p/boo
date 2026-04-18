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

@MainActor class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Enable SSH ControlMaster for connection sharing — allows the file explorer
        // to multiplex on the user's interactive SSH sessions (including password auth).
        setupSSHControlMaster()

        // Start the IPC socket server for child process communication
        BooSocketServer.shared.start()

        windowController = MainWindowController()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)

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

    func applicationWillTerminate(_ notification: Notification) {
        // Save sidebar state (heights, order) to Settings before quit
        windowController?.coordinator?.saveSidebarStateToSettings()
        windowController?.saveSession()
        SSHControlManager.shared.teardownAll()
        BooSocketServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Ask user once before modifying ~/.ssh/config; remember the choice.
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
