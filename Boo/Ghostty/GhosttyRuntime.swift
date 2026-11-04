import CGhostty
import Cocoa

extension Notification.Name {
    static let ghosttyPwdChanged = Notification.Name("ghosttyPwdChanged")
    static let ghosttyChildExited = Notification.Name("ghosttyChildExited")
    static let ghosttyAction = Notification.Name("ghosttyAction")
    /// Posted when Ghostty requests a URL to be opened (e.g. cmd+click on a hyperlink).
    /// userInfo["url"] is a URL. Only http/https URLs are posted; other schemes fall through.
    static let ghosttyOpenURL = Notification.Name("ghosttyOpenURL")
}

/// Singleton managing the Ghostty app instance.
@MainActor final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var settingsObserver: Any?
    private var profilesObserver: Any?

    /// All active surfaces that need config updates.
    private var surfaces: [ghostty_surface_t] = []
    /// The profile each surface shows; surfaces not listed use `config`.
    private var surfaceProfiles: [ghostty_surface_t: Profile] = [:]
    /// Configs built for profiles that change the surface, by profile name.
    /// Rebuilt lazily after every reload.
    private var profileConfigs: [String: (profile: Profile, config: ghostty_config_t)] = [:]

    func registerSurface(_ surface: ghostty_surface_t) {
        surfaces.append(surface)
    }

    func unregisterSurface(_ surface: ghostty_surface_t) {
        surfaces.removeAll { $0 == surface }
        surfaceProfiles[surface] = nil
    }

    /// Shows `profile` on `surface` (nil: the global settings). Only fields
    /// that change the look (theme, font, shader) need a config of their own.
    func setProfile(_ profile: Profile?, for surface: ghostty_surface_t) {
        let effective = profile?.changesSurface == true ? profile : nil
        let previous = surfaceProfiles[surface]
        guard previous != effective else { return }
        surfaceProfiles[surface] = effective
        guard let cfg = effectiveConfig(for: surface) else { return }
        pushConfig(cfg, to: surface)
    }

    private func effectiveConfig(for surface: ghostty_surface_t) -> ghostty_config_t? {
        guard let profile = surfaceProfiles[surface] else { return config }
        if let cached = profileConfigs[profile.name] {
            if cached.profile == profile { return cached.config }
            // Edited since it was built; surfaces copy their config, so the
            // stale one can go now.
            ghostty_config_free(cached.config)
            profileConfigs[profile.name] = nil
        }
        guard let cfg = buildConfig(profile: profile) else { return config }
        profileConfigs[profile.name] = (profile, cfg)
        return cfg
    }

    private func pushConfig(_ cfg: ghostty_config_t, to surface: ghostty_surface_t) {
        // Reset font size first — Ghostty tracks manual adjustments (Cmd+/-)
        // and skips config-based font changes if the flag is set.
        "reset_font_size".withCString { action in
            _ = ghostty_surface_binding_action(surface, action, 15)
        }
        ghostty_surface_update_config(surface, cfg)
    }

    /// Find Ghostty's resources directory so shell integration (OSC 7) works.
    /// Looks for bundled resources in the app bundle first, then next to the
    /// executable (standalone), then falls back to the Vendor directory (development).
    nonisolated static func resolveResourcesDir(
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

        // Expose the socket path so child processes can communicate with Boo.
        // BOO_TERM is set only via Ghostty env (below) so the shell integration guard
        // works even when BOO_SOCK propagates to child processes outside Boo.
        setenv("BOO_SOCK", BooSocketServer.shared.socketPath, 1)
        // Launched from another Boo terminal (`open`, `make run`): that tab's
        // variables would leak into every shell here. BOO_SHELL_INTEGRATION
        // alone makes the integration skip itself, so `boo` is not on PATH.
        for key in ["BOO_SHELL_INTEGRATION", "BOO_TERM", "BOO_PANE_ID", "BOO_TAB_ID", "BOO_TOKEN", "BOO_AGENT"] {
            unsetenv(key)
        }

        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let rc = ghostty_init(UInt(argc), argv)
        guard rc == 0 else {
            booLog(.error, .app, "ghostty_init failed with code \(rc)")
            return
        }

        config = buildConfig()

        var rtConfig = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeup,
            action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboard,
            write_clipboard_cb: ghosttyWriteClipboard,
            close_surface_cb: ghosttyCloseSurface)

        guard let config else {
            booLog(.error, .app, "Failed to build Ghostty config")
            return
        }
        app = ghostty_app_new(&rtConfig, config)
        if app == nil {
            booLog(.error, .app, "Failed to create Ghostty app")
        } else {
            booLog(.info, .app, "Ghostty app initialized")
            // The event loop is pumped on demand via `wakeup_cb` (ghosttyWakeup),
            // matching upstream Ghostty. `ghostty_app_tick` only drains the app
            // mailbox — cursor blink and rendering run on each surface's own
            // render thread — so a periodic tick is pure wasted wakeups. A
            // previous 30fps repeating timer in .common mode kept the CPU busy
            // and defeated App Nap while idle; it was the main battery drain.
        }

        // Listen for settings changes and push new config to all surfaces
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }
        profilesObserver = NotificationCenter.default.addObserver(
            forName: .profilesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadProfiles() }
        }
    }

    /// Build a fresh Ghostty config from Boo settings.
    private func buildConfig(profile: Profile? = nil) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        guard let cfg = cfg else { return nil }

        // Skip ghostty_config_load_default_files — Boo manages its own
        // settings.  Loading the user's Ghostty config would prepend values
        // for repeatable keys like font-family, making our settings ignored.
        // Overrides go in ~/.boo/ghostty-user.conf instead (applyBooSettings).
        applyBooSettings(to: cfg, profile: profile)
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

        // Profile configs inherit the global settings, so they are rebuilt too.
        let oldProfileConfigs = profileConfigs
        profileConfigs = [:]

        // Push config to each existing surface (font, colors, cursor, etc.).
        for surface in surfaces {
            pushConfig(effectiveConfig(for: surface) ?? newConfig, to: surface)
        }

        if let old = old { ghostty_config_free(old) }
        for entry in oldProfileConfigs.values { ghostty_config_free(entry.config) }

        booLog(.info, .app, "Config reloaded, pushed to \(surfaces.count) surface(s)")
    }

    /// Write Boo settings as a Ghostty config file and load it.
    /// Profiles in `profiles.json` changed: surfaces showing an edited
    /// profile get it rebuilt.
    private func reloadProfiles() {
        let store = ProfileStore.shared
        for (surface, profile) in surfaceProfiles {
            setProfile(store.profile(named: profile.name), for: surface)
        }
    }

    private func applyBooSettings(to cfg: ghostty_config_t, profile: Profile? = nil) {
        let settings = AppSettings.shared
        let theme = profile?.theme.flatMap { settings.theme(named: $0) } ?? settings.theme

        var lines: [String] = []

        // Font
        lines.append("font-family = \(profile?.fontFamily ?? settings.fontName)")
        lines.append("font-size = \(Int(profile?.fontSize ?? settings.fontSize))")

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
        lines.append("window-padding-x = \(Int(GhosttyView.gridPadding))")
        lines.append("window-padding-y = \(Int(GhosttyView.gridPadding))")
        lines.append("confirm-close-surface = false")
        lines.append("quit-after-last-window-closed = false")
        lines.append("mouse-hide-while-typing = true")
        lines.append("cursor-click-to-move = true")
        lines.append("scrollback-limit = 10000000")
        // OSC 52 reads hand the clipboard to whatever runs in the terminal,
        // including a remote host: ask first (ghosttyConfirmReadClipboard).
        lines.append("clipboard-read = ask")
        lines.append("clipboard-write = allow")
        lines.append("copy-on-select = clipboard")

        // A profile's shader ("" = none) replaces the global one.
        if let shader = ShaderLibrary.path(for: profile?.shader ?? settings.terminalShader) {
            lines.append("custom-shader = \(shader)")
            lines.append("custom-shader-animation = true")
        }

        // Write temp config file and load it
        var tmpPath = BooPaths.ghosttyConfigFile
        if let profile {
            tmpPath = (tmpPath as NSString).deletingPathExtension + "-profile-\(RuleSet.hash(profile.name)).conf"
        }
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

        // Last, so its options win over Boo's. Repeatable keys (font-family,
        // keybind) append instead: an empty value first resets them.
        let userPath = BooPaths.ghosttyUserConfigFile
        if FileManager.default.fileExists(atPath: userPath) {
            userPath.withCString { ghostty_config_load_file(cfg, $0) }
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
