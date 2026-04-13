import CGhostty
import Cocoa

extension Notification.Name {
    static let ghosttyPwdChanged = Notification.Name("ghosttyPwdChanged")
    static let ghosttyChildExited = Notification.Name("ghosttyChildExited")
    static let ghosttyAction = Notification.Name("ghosttyAction")
}

// C-compatible callback functions
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        guard let app = GhosttyRuntime.shared.app else { return }
        ghostty_app_tick(app)
    }
}

private func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    // Get the GhosttyView from the surface's userdata
    func viewFromTarget() -> GhosttyView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface,
            let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttyView>.fromOpaque(userdata).takeUnretainedValue()
    }

    switch action.tag {
    case GHOSTTY_ACTION_PWD:
        guard let pwdPtr = action.action.pwd.pwd else { return false }
        let path = String(cString: pwdPtr)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onPwdChanged?(path)
        }
        return true

    case GHOSTTY_ACTION_SET_TITLE:
        guard let titlePtr = action.action.set_title.title else { return false }
        let title = String(cString: titlePtr)
        guard let view = viewFromTarget() else { return false }
        // Intercept BOO_LS: prefixed titles — directory listings, not real titles.
        if title.hasPrefix("BOO_LS:") {
            let payload = String(title.dropFirst("BOO_LS:".count))
            if let colonIdx = payload.firstIndex(of: ":") {
                let path = String(payload[..<colonIdx])
                let output = String(payload[payload.index(after: colonIdx)...])
                DispatchQueue.main.async { [weak view] in
                    view?.onDirectoryListing?(path, output)
                }
            }
            return true
        }

        // Intercept OSC 9999 command tracking events emitted by shell integration scripts.
        // Format (packed into SET_TITLE): "BOO_CMD:<action>;<data>"
        // Actions: cmd_start (data = command string), cmd_end (data = exit code)
        if title.hasPrefix("BOO_CMD:") {
            let payload = String(title.dropFirst("BOO_CMD:".count))
            if let semicolonIdx = payload.firstIndex(of: ";") {
                let action = String(payload[..<semicolonIdx])
                let data = String(payload[payload.index(after: semicolonIdx)...])
                switch action {
                case "cmd_start":
                    DispatchQueue.main.async { [weak view] in
                        view?.onCommandStart?(data)
                    }
                case "cmd_end":
                    if let code = Int32(data) {
                        DispatchQueue.main.async { [weak view] in
                            view?.onCommandEnd?(code)
                        }
                    }
                default:
                    break
                }
            }
            return true
        }

        DispatchQueue.main.async { [weak view] in
            view?.onTitleChanged?(title)
        }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onProcessExited?()
        }
        return true

    // Window management actions — forward to MainWindowController via notification
    case GHOSTTY_ACTION_NEW_SPLIT:
        let direction = action.action.new_split
        let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAction, object: nil,
                userInfo: [
                    "action": "new_split",
                    "direction": direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT
                        ? "vertical" : "horizontal",
                    "surface": surface as Any
                ])
        }
        return true

    case GHOSTTY_ACTION_GOTO_SPLIT:
        let dir = action.action.goto_split
        let dirStr: String
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: dirStr = "previous"
        case GHOSTTY_GOTO_SPLIT_NEXT: dirStr = "next"
        default: return false
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAction, object: nil,
                userInfo: [
                    "action": "goto_split", "direction": dirStr
                ])
        }
        return true

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "equalize_splits"])
        }
        return true

    case GHOSTTY_ACTION_CLOSE_TAB:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "close_surface"])
        }
        return true

    case GHOSTTY_ACTION_NEW_TAB:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "new_tab"])
        }
        return true

    case GHOSTTY_ACTION_NEW_WINDOW:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "new_workspace"])
        }
        return true

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAction, object: nil, userInfo: ["action": "toggle_fullscreen"])
        }
        return true

    case GHOSTTY_ACTION_CLOSE_WINDOW:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "close_window"])
        }
        return true

    case GHOSTTY_ACTION_QUIT:
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
        return true

    case GHOSTTY_ACTION_OPEN_CONFIG:
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "open_settings"])
        }
        return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
        DispatchQueue.main.async {
            GhosttyRuntime.shared.reloadConfig()
        }
        return true

    case GHOSTTY_ACTION_SCROLLBAR:
        let sb = action.action.scrollbar
        guard let view = viewFromTarget() else { return false }
        let scrollbar = GhosttyView.GhosttyScrollbar(
            total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
        DispatchQueue.main.async { [weak view] in
            view?.onScrollbarChanged?(scrollbar)
        }
        return true

    default:
        return false
    }
}

private func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?
) -> Bool {
    false
}

private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ prompt: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
}

private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirmed: Bool
) {
    guard let content = content, count > 0 else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    if let data = content[0].data {
        pb.setString(String(cString: data), forType: .string)
    }
}

private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .ghosttyChildExited,
            object: nil,
            userInfo: ["processAlive": processAlive]
        )
    }
}

/// Singleton managing the Ghostty app instance.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var settingsObserver: Any?
    private var tickTimer: Timer?

    /// All active surfaces that need config updates.
    private var surfaces: [ghostty_surface_t] = []

    func registerSurface(_ surface: ghostty_surface_t) {
        surfaces.append(surface)
    }

    func unregisterSurface(_ surface: ghostty_surface_t) {
        surfaces.removeAll { $0 == surface }
    }

    /// Find Ghostty's resources directory so shell integration (OSC 7) works.
    /// Looks for bundled resources in the app bundle first, then next to the
    /// executable (standalone), then falls back to the Vendor directory (development).
    static func resolveResourcesDir(
        execPath: String?,
        bundleResourcePath: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let execPath else { return nil }
        let resolved = (execPath as NSString).resolvingSymlinksInPath
        let execDir = (resolved as NSString).deletingLastPathComponent

        // 1. App bundle: Contents/Resources/ghostty/
        if let bundlePath = bundleResourcePath {
            let bundleRes = bundlePath + "/ghostty"
            if fileExists(bundleRes + "/shell-integration") {
                return bundleRes
            }
        }

        // 2. Bundled: ghostty-resources/ghostty/ next to the executable
        let bundled = execDir + "/ghostty-resources/ghostty"
        if fileExists(bundled + "/shell-integration") {
            return bundled
        }

        // 3. Development fallback: walk up to find Vendor/ghostty/zig-out
        var dir = execDir
        for _ in 0..<10 {
            let candidate = dir + "/Vendor/ghostty/zig-out/share/ghostty"
            if fileExists(candidate + "/shell-integration") {
                return candidate
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private static func findResourcesDir() -> String? {
        resolveResourcesDir(
            execPath: ProcessInfo.processInfo.arguments.first,
            bundleResourcePath: Bundle.main.resourcePath
        )
    }

    private init() {
        // Set resources dir before ghostty_init so shell integration is available
        if let dir = GhosttyRuntime.findResourcesDir() {
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
            booLog(.info, .app, "Set GHOSTTY_RESOURCES_DIR = \(dir)")

            // Also set TERMINFO so xterm-ghostty terminfo is found
            let terminfo = ((dir as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("terminfo")
            if FileManager.default.fileExists(atPath: terminfo) {
                setenv("TERMINFO", terminfo, 0)  // don't overwrite if already set
            }
        } else {
            booLog(.warning, .app, "Could not find resources dir — shell integration disabled")
        }

        // Expose the socket path so child processes can communicate with Boo
        setenv("BOO_SOCK", BooSocketServer.shared.socketPath, 1)

        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let rc = ghostty_init(UInt(argc), argv)
        guard rc == 0 else {
            booLog(.error, .app, "ghostty_init failed with code \(rc)")
            return
        }

        config = buildConfig()

        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = nil
        rtConfig.supports_selection_clipboard = false
        rtConfig.wakeup_cb = ghosttyWakeup
        rtConfig.action_cb = ghosttyAction
        rtConfig.read_clipboard_cb = ghosttyReadClipboard
        rtConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        rtConfig.write_clipboard_cb = ghosttyWriteClipboard
        rtConfig.close_surface_cb = ghosttyCloseSurface

        app = ghostty_app_new(&rtConfig, config)
        if app == nil {
            booLog(.error, .app, "Failed to create Ghostty app")
        } else {
            booLog(.info, .app, "Ghostty app initialized")
            // Periodic tick drives cursor blink and other time-based rendering.
            // Add to .common modes so the timer fires during event tracking
            // (resize, scroll) and modal panels, not just the default mode.
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let app = self?.app else { return }
                ghostty_app_tick(app)
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }

        // Listen for settings changes and push new config to all surfaces
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadConfig()
        }
    }

    /// Build a fresh Ghostty config from Boo settings.
    private func buildConfig() -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        guard let cfg = cfg else { return nil }

        // Skip ghostty_config_load_default_files — Boo manages its own
        // settings.  Loading the user's Ghostty config would prepend values
        // for repeatable keys like font-family, making our settings ignored.
        applyBooSettings(to: cfg)
        ghostty_config_finalize(cfg)

        return cfg
    }

    /// Rebuild config and push to all active surfaces.
    func reloadConfig() {
        guard let newConfig = buildConfig() else { return }

        let old = config
        config = newConfig

        // Update the app-level config for new surfaces.
        if let app = app {
            ghostty_app_update_config(app, newConfig)
        }

        // Push config to each existing surface (font, colors, cursor, etc.).
        // Reset font size first — Ghostty tracks manual adjustments (Cmd+/-)
        // and skips config-based font changes if the flag is set.
        for surface in surfaces {
            "reset_font_size".withCString { action in
                _ = ghostty_surface_binding_action(surface, action, 15)
            }
            ghostty_surface_update_config(surface, newConfig)
        }

        if let old = old { ghostty_config_free(old) }

        booLog(.info, .app, "Config reloaded, pushed to \(surfaces.count) surface(s)")
    }

    /// Write Boo settings as a Ghostty config file and load it.
    private func applyBooSettings(to cfg: ghostty_config_t) {
        let settings = AppSettings.shared
        let theme = settings.theme

        var lines: [String] = []

        // Font
        lines.append("font-family = \(settings.fontName)")
        lines.append("font-size = \(Int(settings.fontSize))")

        // Cursor
        switch settings.cursorStyle {
        case .block: lines.append("cursor-style = block")
        case .beam: lines.append("cursor-style = bar")
        case .underline: lines.append("cursor-style = underline")
        case .blockOutline: lines.append("cursor-style = block_hollow")
        }
        lines.append("cursor-style-blink = true")
        lines.append("cursor-opacity = 1")
        lines.append("cursor-text-color = \(hexColor(theme.background))")
        lines.append("shell-integration-features = no-cursor")
        lines.append("unfocused-split-opacity = 0.85")

        // Colors from theme
        lines.append("background = \(hexColor(theme.background))")
        lines.append("foreground = \(hexColor(theme.foreground))")
        lines.append("cursor-color = \(hexColor(theme.cursor))")
        lines.append("selection-background = \(hexNSColor(theme.selection))")
        lines.append("selection-foreground = \(hexColor(theme.foreground))")

        // ANSI palette (0-15)
        for (i, c) in theme.ansiColors.enumerated() {
            lines.append("palette = \(i)=\(hexColor(c))")
        }

        // Terminal type — use xterm-256color for maximum compatibility
        // (xterm-ghostty requires ghostty terminfo to be installed)
        lines.append("term = xterm-256color")

        // Window / terminal behavior
        lines.append("window-decoration = none")
        lines.append("window-padding-x = 3")
        lines.append("window-padding-y = 3")
        lines.append("confirm-close-surface = false")
        lines.append("quit-after-last-window-closed = false")
        lines.append("mouse-hide-while-typing = true")
        lines.append("scrollback-limit = 10000000")
        lines.append("clipboard-read = allow")
        lines.append("clipboard-write = allow")
        lines.append("copy-on-select = clipboard")

        // Write temp config file and load it
        let tmpPath = BooPaths.ghosttyConfigFile
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            booLog(.debug, .app, "Config written to \(tmpPath) (\(lines.count) options)")
        } catch {
            booLog(.error, .app, "Failed to write config: \(error)")
        }

        tmpPath.withCString { path in
            ghostty_config_load_file(cfg, path)
        }
    }

    private func hexColor(_ c: TerminalColor) -> String {
        String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }

    private func hexNSColor(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(
            format: "#%02x%02x%02x",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }
}
