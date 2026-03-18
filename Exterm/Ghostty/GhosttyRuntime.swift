import Cocoa
import CGhostty

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
              let userdata = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttyView>.fromOpaque(userdata).takeUnretainedValue()
    }

    switch action.tag {
    case GHOSTTY_ACTION_PWD:
        guard let pwdPtr = action.action.pwd.pwd else { return false }
        let path = String(cString: pwdPtr)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async {
            view.onPwdChanged?(path)
        }
        return true

    case GHOSTTY_ACTION_SET_TITLE:
        guard let titlePtr = action.action.set_title.title else { return false }
        let title = String(cString: titlePtr)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async {
            view.onTitleChanged?(title)
        }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async {
            view.onProcessExited?()
        }
        return true

    // Window management actions — forward to MainWindowController via notification
    case GHOSTTY_ACTION_NEW_SPLIT:
        let direction = action.action.new_split
        let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: [
                "action": "new_split",
                "direction": direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT ? "vertical" : "horizontal",
                "surface": surface as Any,
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
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: [
                "action": "goto_split", "direction": dirStr,
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
            NotificationCenter.default.post(name: .ghosttyAction, object: nil, userInfo: ["action": "toggle_fullscreen"])
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

    default:
        return false
    }
}

private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    return false
}

private func ghosttyConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ prompt: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
}

private func ghosttyWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirmed: Bool) {
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
    /// Looks for bundled resources next to the executable first (standalone),
    /// then falls back to the Vendor directory (development).
    private static func findResourcesDir() -> String? {
        let execDir: String
        if let execPath = ProcessInfo.processInfo.arguments.first {
            // Resolve symlinks to get the real executable location
            let resolved = (execPath as NSString).resolvingSymlinksInPath
            execDir = (resolved as NSString).deletingLastPathComponent
        } else {
            return nil
        }

        // 1. Bundled: ghostty-resources/ghostty/ next to the executable
        let bundled = execDir + "/ghostty-resources/ghostty"
        if FileManager.default.fileExists(atPath: bundled + "/shell-integration") {
            return bundled
        }

        // 2. Development fallback: walk up to find Vendor/ghostty/zig-out
        var dir = execDir
        for _ in 0..<10 {
            let candidate = dir + "/Vendor/ghostty/zig-out/share/ghostty"
            if FileManager.default.fileExists(atPath: candidate + "/shell-integration") {
                return candidate
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private init() {
        // Set resources dir before ghostty_init so shell integration is available
        if let dir = GhosttyRuntime.findResourcesDir() {
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
            NSLog("[Ghostty] Set GHOSTTY_RESOURCES_DIR = \(dir)")

            // Also set TERMINFO so xterm-ghostty terminfo is found
            let terminfo = ((dir as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("terminfo")
            if FileManager.default.fileExists(atPath: terminfo) {
                setenv("TERMINFO", terminfo, 0) // don't overwrite if already set
            }
        } else {
            NSLog("[Ghostty] WARNING: Could not find resources dir — shell integration disabled")
        }

        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let rc = ghostty_init(UInt(argc), argv)
        guard rc == 0 else {
            NSLog("[Ghostty] ghostty_init failed with code \(rc)")
            return
        }

        // Install shell integration BEFORE building config so ZDOTDIR path is available
        GhosttyRuntime.installShellIntegration()

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
            NSLog("[Ghostty] Failed to create app")
        } else {
            NSLog("[Ghostty] App initialized")
            // Periodic tick drives cursor blink and other time-based rendering
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let app = self?.app else { return }
                ghostty_app_tick(app)
            }
        }

        // Listen for settings changes and push new config to all surfaces
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadConfig()
        }
    }

    /// Write Exterm's shell integration scripts to ~/.exterm/shell-integration/.
    ///
    /// SSH/Docker remote CWD injection approach:
    /// - For key-based auth: ssh wrapper uses ControlMaster to first inject the
    ///   OSC 7 reporter, then connects the interactive session over the same socket.
    /// - For password auth: falls back to plain `ssh` — explorer uses title/process
    ///   detection instead. The remote CWD won't auto-update on `cd`, but the
    ///   explorer will show the remote home directory.
    ///
    /// Shell functions are loaded via ZDOTDIR (zsh) and BASH_ENV (bash).
    private static func installShellIntegration() {
        let dir = ExtermPaths.shellIntegrationDir
        let zdotdir = (dir as NSString).appendingPathComponent("zsh")
        try? FileManager.default.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)

        // Remote init: a POSIX-compatible snippet that sets up OSC 7 reporting.
        writeScript(
            dir: dir, name: "remote-init.sh", executable: false,
            content: [
                #"__exterm_osc7() { printf '\033]7;file://%s%s\a' "$(hostname)" "$PWD"; }"#,
                #"if [ -n "$ZSH_VERSION" ]; then"#,
                #"  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd __exterm_osc7"#,
                #"  precmd_functions+=(__exterm_osc7)"#,
                #"elif [ -n "$BASH_VERSION" ]; then"#,
                #"  PROMPT_COMMAND="__exterm_osc7${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#,
                #"fi"#,
                #"__exterm_osc7"#,
            ]
        )

        // Compute base64 blob from remote-init.sh
        let remoteInitPath = (dir as NSString).appendingPathComponent("remote-init.sh")
        let b64: String
        if let data = FileManager.default.contents(atPath: remoteInitPath) {
            b64 = data.base64EncodedString()
        } else {
            b64 = ""
        }

        // SSH wrapper function: tries ControlMaster injection (works with key auth),
        // falls back to plain ssh (works with password auth, no remote CWD tracking).
        let sshFunction = [
            "ssh() {",
            "  # Detect interactive (no remote command after host)",
            "  local _int=1 _skip=0 _host= _a",
            "  for _a in \"$@\"; do",
            "    if [ \"$_skip\" = 1 ]; then _skip=0; continue; fi",
            "    case \"$_a\" in",
            "      -[bcDeFIiJLlmOopQRSWw]) _skip=1 ;;",
            "      -*) ;;",
            "      *) if [ -z \"$_host\" ]; then _host=\"$_a\"; else _int=0; break; fi ;;",
            "    esac",
            "  done",
            "",
            "  if [ \"$_int\" = 1 ] && [ -n \"$_host\" ]; then",
            "    # Try ControlMaster injection (non-blocking, fails gracefully with password auth)",
            "    local _sock=\"/tmp/exterm-cm-$$\"",
            "    if echo '\(b64)' | command ssh -o BatchMode=yes -o ControlMaster=yes \\",
            "         -o \"ControlPath=$_sock\" -o ControlPersist=60s \"$@\" \\",
            "         'B=$(cat); eval \"$(echo $B | base64 -d)\" 2>/dev/null' 2>/dev/null; then",
            "      # Injection succeeded — connect over the ControlMaster socket",
            "      command ssh -o \"ControlPath=$_sock\" \"$@\"",
            "      return",
            "    fi",
            "  fi",
            "  # Fallback: plain ssh (password auth, non-interactive, or injection failed)",
            "  command ssh \"$@\"",
            "}",
        ]

        // Docker wrapper: injects init into interactive docker exec sessions
        let dockerFunction = [
            "docker() {",
            "  local _isexec=0",
            "  case \"$*\" in *exec*) _isexec=1 ;; esac",
            "  if [ \"$_isexec\" = 1 ]; then",
            "    local _fe=0 _ctr= _ac=0 _a",
            "    for _a in \"$@\"; do",
            "      if [ \"$_fe\" = 0 ]; then [ \"$_a\" = exec ] && _fe=1; continue; fi",
            "      if [ -z \"$_ctr\" ]; then case \"$_a\" in -*) continue ;; esac; _ctr=\"$_a\"; continue; fi",
            "      _ac=1; break",
            "    done",
            "    if [ \"$_ac\" = 0 ] && [ -n \"$_ctr\" ]; then",
            "      command docker exec -it \"$_ctr\" sh -c 'eval \"$(echo \(b64) | base64 -d)\" 2>/dev/null; exec ${SHELL:-sh} -li'",
            "      return",
            "    fi",
            "  fi",
            "  command docker \"$@\"",
            "}",
        ]

        writeScript(
            dir: dir, name: "exterm-init.sh", executable: false,
            content: (sshFunction + [""] + dockerFunction)
        )

        // ZDOTDIR shim for zsh
        let realHome = NSHomeDirectory()
        writeScript(
            dir: zdotdir, name: ".zshenv", executable: false,
            content: [
                "export ZDOTDIR=\"\(realHome)\"",
                "[ -f \"$ZDOTDIR/.zshenv\" ] && source \"$ZDOTDIR/.zshenv\"",
                "if [[ -o interactive ]]; then",
                "  source \"\(dir)/exterm-init.sh\"",
                "fi",
            ]
        )

        // BASH_ENV for bash
        writeScript(
            dir: dir, name: "bash-init.sh", executable: false,
            content: [
                "[ -f ~/.bashrc ] && source ~/.bashrc",
                "source \"\(dir)/exterm-init.sh\"",
            ]
        )

        setenv("ZDOTDIR", zdotdir, 1)
        setenv("BASH_ENV", (dir as NSString).appendingPathComponent("bash-init.sh"), 1)
        setenv("EXTERM_SHELL_INTEGRATION", dir, 1)
    }

    private static func writeScript(dir: String, name: String, executable: Bool, content: [String]) {
        let path = (dir as NSString).appendingPathComponent(name)
        let text = content.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    /// Build a fresh Ghostty config from Exterm settings.
    private func buildConfig() -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        guard let cfg = cfg else { return nil }

        ghostty_config_load_default_files(cfg)
        applyExtermSettings(to: cfg)
        ghostty_config_finalize(cfg)

        return cfg
    }

    /// Rebuild config and push to all active surfaces.
    func reloadConfig() {
        guard let newConfig = buildConfig() else { return }

        if let old = config { ghostty_config_free(old) }
        config = newConfig

        // Update the app config — this propagates to ALL surfaces automatically
        if let app = app {
            ghostty_app_update_config(app, newConfig)
        }

        NSLog("[Ghostty] Config reloaded via app, \(surfaces.count) surface(s)")
    }

    /// Write Exterm settings as a Ghostty config file and load it.
    private func applyExtermSettings(to cfg: ghostty_config_t) {
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

        // Inject shell integration env vars via Ghostty's env config.
        // ZDOTDIR makes zsh load our shim .zshrc which defines ssh/docker functions.
        // BASH_ENV makes bash source our init before interactive startup.
        // Using Ghostty env config ensures these are set in the child process
        // regardless of when surfaces are created.
        let shellIntegDir = ExtermPaths.shellIntegrationDir
        lines.append("environment = EXTERM_SHELL_INTEGRATION=\(shellIntegDir)")
        lines.append("environment = ZDOTDIR=\(shellIntegDir)/zsh")
        lines.append("environment = BASH_ENV=\(shellIntegDir)/bash-init.sh")

        // Window / terminal behavior
        lines.append("window-decoration = none")
        lines.append("window-padding-x = 8")
        lines.append("window-padding-y = 4")
        lines.append("confirm-close-surface = false")
        lines.append("quit-after-last-window-closed = false")
        lines.append("mouse-hide-while-typing = true")
        lines.append("scrollback-limit = 10000000")
        lines.append("clipboard-read = allow")
        lines.append("clipboard-write = allow")
        lines.append("copy-on-select = clipboard")

        // Write temp config file and load it
        let tmpPath = ExtermPaths.ghosttyConfigFile
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            NSLog("[Ghostty] Config written to \(tmpPath) (\(lines.count) options)")
        } catch {
            NSLog("[Ghostty] Failed to write config: \(error)")
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
        return String(format: "#%02x%02x%02x",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
