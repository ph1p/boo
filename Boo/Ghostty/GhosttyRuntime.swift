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

// C-compatible callback functions
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        guard let app = GhosttyRuntime.shared.app else { return }
        ghostty_app_tick(app)
    }
}

/// Post a `.ghosttyAction` scoped to the window hosting `view` (nil → active window).
private func postWindowAction(from view: GhosttyView?, _ userInfo: [String: String]) {
    DispatchQueue.main.async { [weak view] in
        NotificationCenter.default.post(name: .ghosttyAction, object: view?.window, userInfo: userInfo)
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

        // Intercept BOO_CMD: prefixed SET_TITLE events from Boo's shell integration scripts.
        // cmd_end is handled natively via GHOSTTY_ACTION_COMMAND_FINISHED (OSC 133) — only
        // cmd_start remains here, used to set isCommandRunning on the tab.
        if title.hasPrefix("BOO_CMD:") {
            let payload = String(title.dropFirst("BOO_CMD:".count))
            if let semicolonIdx = payload.firstIndex(of: ";") {
                let action = String(payload[..<semicolonIdx])
                let data = String(payload[payload.index(after: semicolonIdx)...])
                if action == "cmd_start" {
                    DispatchQueue.main.async { [weak view] in
                        view?.atBooPrompt = false
                        view?.commandHistory.start(data)
                        view?.onCommandStart?(data)
                        view?.onPromptMarksChanged?()
                    }
                } else if action == "cmd_end" {
                    // Sent at every prompt, the first one included.
                    DispatchQueue.main.async { [weak view] in view?.atBooPrompt = true }
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

    case GHOSTTY_ACTION_COMMAND_FINISHED:
        guard let view = viewFromTarget() else { return false }
        let exitCode = Int32(action.action.command_finished.exit_code)
        let duration = action.action.command_finished.duration
        DispatchQueue.main.async { [weak view] in
            view?.commandHistory.finish(exitCode: exitCode, durationNanos: duration)
            view?.onCommandEnd?(exitCode)
            view?.onPromptMarksChanged?()
        }
        return true

    case GHOSTTY_ACTION_PROGRESS_REPORT:
        guard let view = viewFromTarget() else { return false }
        let raw = action.action.progress_report
        let report: TerminalProgress.Report
        switch raw.state {
        case GHOSTTY_PROGRESS_STATE_SET: report = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: report = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: report = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: report = .pause
        default: report = .remove
        }
        let percent = Int(raw.progress)
        DispatchQueue.main.async { [weak view] in
            view?.onProgressReport?(report, percent)
        }
        return true

    case GHOSTTY_ACTION_RING_BELL:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onBell?()
        }
        return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        guard let view = viewFromTarget() else { return false }
        let notifTitle = action.action.desktop_notification.title.map { String(cString: $0) } ?? ""
        let notifBody = action.action.desktop_notification.body.map { String(cString: $0) } ?? ""
        DispatchQueue.main.async { [weak view] in
            view?.onDesktopNotification?(notifTitle, notifBody)
        }
        return true

    // Window management actions — forward to MainWindowController via notification.
    // `object` is the surface's window so only that window reacts; nil (app-level
    // action, no surface) goes to the active window.
    case GHOSTTY_ACTION_NEW_SPLIT:
        let direction = action.action.new_split
        let vertical = direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT
        postWindowAction(
            from: viewFromTarget(), ["action": "new_split", "direction": vertical ? "vertical" : "horizontal"])
        return true

    case GHOSTTY_ACTION_GOTO_SPLIT:
        let dir = action.action.goto_split
        let dirStr: String
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: dirStr = "previous"
        case GHOSTTY_GOTO_SPLIT_NEXT: dirStr = "next"
        case GHOSTTY_GOTO_SPLIT_LEFT: dirStr = "left"
        case GHOSTTY_GOTO_SPLIT_RIGHT: dirStr = "right"
        case GHOSTTY_GOTO_SPLIT_UP: dirStr = "up"
        case GHOSTTY_GOTO_SPLIT_DOWN: dirStr = "down"
        default: return false
        }
        postWindowAction(from: viewFromTarget(), ["action": "goto_split", "direction": dirStr])
        return true

    case GHOSTTY_ACTION_RESIZE_SPLIT:
        let resize = action.action.resize_split
        let dirStr: String
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT: dirStr = "left"
        case GHOSTTY_RESIZE_SPLIT_RIGHT: dirStr = "right"
        case GHOSTTY_RESIZE_SPLIT_UP: dirStr = "up"
        case GHOSTTY_RESIZE_SPLIT_DOWN: dirStr = "down"
        default: return false
        }
        postWindowAction(
            from: viewFromTarget(),
            ["action": "resize_split", "direction": dirStr, "amount": String(resize.amount)])
        return true

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        postWindowAction(from: viewFromTarget(), ["action": "toggle_split_zoom"])
        return true

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        postWindowAction(from: viewFromTarget(), ["action": "equalize_splits"])
        return true

    case GHOSTTY_ACTION_CLOSE_TAB:
        postWindowAction(from: viewFromTarget(), ["action": "close_surface"])
        return true

    case GHOSTTY_ACTION_NEW_TAB:
        postWindowAction(from: viewFromTarget(), ["action": "new_tab"])
        return true

    case GHOSTTY_ACTION_NEW_WINDOW:
        postWindowAction(from: viewFromTarget(), ["action": "new_window"])
        return true

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
        postWindowAction(from: viewFromTarget(), ["action": "toggle_fullscreen"])
        return true

    case GHOSTTY_ACTION_CLOSE_WINDOW:
        postWindowAction(from: viewFromTarget(), ["action": "close_window"])
        return true

    case GHOSTTY_ACTION_QUIT:
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
        return true

    case GHOSTTY_ACTION_OPEN_CONFIG:
        postWindowAction(from: viewFromTarget(), ["action": "open_settings"])
        return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
        DispatchQueue.main.async {
            GhosttyRuntime.shared.reloadConfig()
        }
        return true

    case GHOSTTY_ACTION_OPEN_URL:
        let openURL = action.action.open_url
        guard let urlPtr = openURL.url else { return false }
        let urlString: String
        if openURL.len > 0 {
            urlString = urlPtr.withMemoryRebound(to: UInt8.self, capacity: Int(openURL.len)) {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(openURL.len)), as: UTF8.self)
            }
        } else {
            urlString = String(cString: urlPtr)
        }
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else { return false }
        guard let url = URL(string: urlString) else { return false }
        let view = viewFromTarget()
        DispatchQueue.main.async { [weak view] in
            NotificationCenter.default.post(
                name: .ghosttyOpenURL,
                object: view?.window,
                userInfo: ["url": url]
            )
        }
        return true

    case GHOSTTY_ACTION_SCROLLBAR:
        let sb = action.action.scrollbar
        guard let view = viewFromTarget() else { return false }
        let scrollbar = GhosttyView.GhosttyScrollbar(
            total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
        DispatchQueue.main.async { [weak view] in
            view?.scrollbar = scrollbar
            view?.onScrollbarChanged?(scrollbar)
        }
        return true

    case GHOSTTY_ACTION_START_SEARCH:
        let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchRequested?(needle)
        }
        return true

    case GHOSTTY_ACTION_END_SEARCH:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchEnded?()
        }
        return true

    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let total = Int(action.action.search_total.total)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchTotal?(total)
        }
        return true

    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let selected = Int(action.action.search_selected.selected)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchSelected?(selected)
        }
        return true

    default:
        return false
    }
}

private func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ mimesLen: Int, _ list: Bool
) -> ghostty_clipboard_read_result_e {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    guard let surface = userdata.flatMap({ Unmanaged<GhosttyView>.fromOpaque($0).takeUnretainedValue().surface })
    else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    // Boo only serves text. Ghostty normalizes text-like MIME requests to
    // "text/plain", so anything else (e.g. Kitty image reads) is unavailable.
    let wantsText = (0..<mimesLen).contains { i in
        mimes?[i].map { String(cString: $0) == "text/plain" } ?? false
    }
    let str = NSPasteboard.general.ghosttyStringContents
    let text = wantsText ? str : nil
    guard text != nil || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

    // Ghostty slices `data[0..<len]` without a nil check, so even an empty
    // string needs a real (NUL-terminated) buffer.
    let data = strdup(text ?? "")
    defer { free(data) }
    let available: [String] = list && str != nil ? ["text/plain"] : []
    "text/plain".withCString { mime in
        let contents =
            text == nil ? [] : [ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data!))]
        withCStringArray(available) { avail in
            contents.withUnsafeBufferPointer { contentsBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress, contents_len: contentsBuf.count,
                    available: avail.baseAddress, available_len: avail.count,
                    confirmed: false, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

/// Calls `body` with a temporary C array of NUL-terminated copies of `strings`.
private func withCStringArray<R>(
    _ strings: [String], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> R
) -> R {
    let copies = strings.compactMap { strdup($0) }
    defer { for copy in copies { free(copy) } }
    return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer(body)
}

private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
) {
    // Reached for pastes that paste protection flags and for OSC 52 reads
    // (clipboard-read = ask). Every path must complete or deny `state`, or the
    // request leaks.
    guard let userdata else { return }
    let view = Unmanaged<GhosttyView>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = view.surface else { return }
    guard let confirm,
        request == GHOSTTY_CLIPBOARD_REQUEST_PASTE || request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
    else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
    }
    // The confirm payload is borrowed: copy what the completion needs now.
    let c = confirm.pointee
    var contents: [(mime: String, data: Data)] = []
    for i in 0..<c.contents_len {
        guard let content = c.contents?[i], let mime = content.mime else { continue }
        let data = content.len > 0 && content.data != nil ? Data(bytes: content.data, count: content.len) : Data()
        contents.append((String(cString: mime), data))
    }
    var available: [String] = []
    for i in 0..<c.available_len {
        if let name = c.available?[i] { available.append(String(cString: name)) }
    }
    let canRemember = c.can_remember
    let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    let state = UInt(bitPattern: state)

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let text = contents.first { $0.mime == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) }
            ClipboardConfirmation.ask(isPaste: isPaste, text: text ?? "", canRemember: canRemember, in: view) {
                allowed, remember in
                guard let surface = view.surface else { return }
                let state = UnsafeMutableRawPointer(bitPattern: state)
                guard allowed else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                let buffers = contents.map { item in
                    item.data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar> in
                        let copy = UnsafeMutablePointer<CChar>.allocate(capacity: raw.count + 1)
                        raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: copy, count: raw.count))
                        copy[raw.count] = 0
                        return copy
                    }
                }
                defer { for buffer in buffers { buffer.deallocate() } }
                withCStringArray(contents.map(\.mime)) { mimes in
                    let items = zip(mimes, zip(buffers, contents)).map { mime, pair in
                        ghostty_clipboard_content_s(mime: mime, data: pair.0, len: pair.1.data.count)
                    }
                    withCStringArray(available) { avail in
                        items.withUnsafeBufferPointer { itemsBuf in
                            var complete = ghostty_clipboard_complete_s(
                                contents: itemsBuf.baseAddress, contents_len: itemsBuf.count,
                                available: avail.baseAddress, available_len: avail.count,
                                confirmed: true, remember: remember)
                            ghostty_surface_complete_clipboard_request(surface, &complete, state)
                        }
                    }
                }
            }
        }
    }
}

private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirmed: Bool
) {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
    guard let content = content, count > 0 else { return }
    // Contents are length-delimited and not necessarily NUL-terminated.
    func text(_ c: ghostty_clipboard_content_s) -> String? {
        guard let data = c.data else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: data, count: c.len), as: UTF8.self)
    }
    let entries = (0..<count).map { content[$0] }
    let plain = entries.first { $0.mime.map { String(cString: $0) == "text/plain" } ?? false }
    guard let str = text(plain ?? entries[0]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(str, forType: .string)
}

extension NSPasteboard {
    fileprivate var ghosttyStringContents: String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { url in
                url.isFileURL ? RemoteExplorer.shellEscPath(url.path) : url.absoluteString
            }.joined(separator: " ")
        }
        return string(forType: .string)
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
