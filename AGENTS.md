# Exterm - Explorer Terminal

A macOS terminal emulator with integrated file explorer, workspace management, and remote session support.

## Architecture

### Language & Frameworks
- **Swift** (macOS native, minimum macOS 13)
- **AppKit** for all terminal UI, toolbar, status bar, split panes
- **SwiftUI** for file tree sidebar and settings window only
- **GhosttyKit** for terminal emulation and Metal GPU rendering (full embedding API from ghostty-org/ghostty)
- **CoreText** for terminal text rendering (fallback, NSView.draw)
- **POSIX PTY** via C helper (`CPTYHelper/`) using `forkpty()`

### Build
- Swift Package Manager (`Package.swift`)
- **Prerequisites**: macOS 13+, Xcode CLT, Zig 0.15+ (`brew install zig`)
- **GhosttyKit build**: `cd Vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast`
- **Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain` (if first time)
- `swift build` to build, `make run` to build and launch
- Zero warnings policy

### Project Structure
```
Exterm/
  App/              - AppDelegate, MainWindowController (window, menus, all wiring)
  Terminal/         - VT100Terminal (parser), TerminalSession (PTY + I/O), TerminalBackend (protocol)
  Renderer/         - TerminalView (CoreText rendering, selection, input)
  Models/           - Workspace, Pane, SplitTree, AppSettings, Theme, TerminalTab
  Views/            - ToolbarView, PaneView, StatusBarView, FileTreeView, RemoteFileTreeView, SettingsWindow
  Services/         - FileSystemWatcher (FSEvents), RemoteExplorer (SSH/Docker), KeyMapping, FileIcon
CPTYHelper/         - C library for forkpty() (Swift can't call fork directly)
```

### Ghostty Integration (GhosttyKit Embedded API)

Exterm embeds GhosttyKit as a static library via the C API (`CGhostty/`). Key integration points:

#### Lifecycle
1. `GhosttyRuntime.init()` — singleton, called once at app launch
   - Sets `GHOSTTY_RESOURCES_DIR` env var **before** `ghostty_init()` (required for shell integration)
   - Sets `TERMINFO` env var pointing to bundled terminfo
   - Calls `ghostty_init()` → `ghostty_app_new()` with runtime callbacks
2. `GhosttyView.createSurface()` — creates a `ghostty_surface_t` per terminal tab
   - Each surface has `userdata` pointing to the owning `GhosttyView`
   - Surface is registered with the runtime for config updates

#### Critical: The Wakeup/Tick Loop
Ghostty's internal message queue (surface mailbox) requires the host app to **drain it** by calling `ghostty_app_tick()`. The `wakeup_cb` callback fires from any thread when messages are queued. The wakeup callback **must** dispatch `ghostty_app_tick()` on the main thread:
```swift
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        guard let app = GhosttyRuntime.shared.app else { return }
        ghostty_app_tick(app)
    }
}
```
Without this, **no surface messages are delivered** — PWD changes (OSC 7), title updates, process exit notifications, etc. will silently not arrive. This is the mechanism that turns Ghostty's internal async events into action callbacks.

#### Action Callback Chain
`ghostty_action` C callback → dispatches to main thread → calls `GhosttyView.onPwdChanged` / `onTitleChanged` / `onProcessExited` → `PaneView` delegate → `MainWindowController` → `TerminalBridge` + sidebar update.

Key actions:
- `GHOSTTY_ACTION_PWD` — shell `cd` detected via OSC 7 (requires shell integration)
- `GHOSTTY_ACTION_SET_TITLE` — terminal title change (used for remote session detection)
- `GHOSTTY_ACTION_SHOW_CHILD_EXITED` — shell process exited

#### Shell Integration & Resources
Ghostty injects shell hooks (zsh: ZDOTDIR override, bash: ENV, fish/elvish: XDG_DATA_DIRS) that make the shell emit OSC 7 on `cd`. This requires the resources directory containing `shell-integration/` scripts.

**Resource bundling** (`Makefile`): `make build` copies `Vendor/ghostty/zig-out/share/ghostty/` and `share/terminfo/` next to the executable as `ghostty-resources/`. The runtime finds them relative to the executable path.

**Resolution order** (`GhosttyRuntime.findResourcesDir()`):
1. `{execDir}/ghostty-resources/ghostty/` — bundled (standalone)
2. Walk up to `Vendor/ghostty/zig-out/share/ghostty` — development fallback

#### Remote Shell Integration (SSH/Docker CWD tracking)
Ghostty's shell integration only injects OSC 7 hooks into the **local** shell. Remote shells (SSH, Docker) need their own mechanism. Exterm solves this with wrapper scripts:

**How it works** (`GhosttyRuntime.installShellIntegration()`):
1. Writes `~/.exterm/shell-integration/remote-init.sh` — a POSIX-compatible snippet that sets up `__exterm_osc7()` function and registers it as chpwd/PROMPT_COMMAND hook (works in zsh and bash)
2. Writes `~/.exterm/shell-integration/bin/ssh` — a wrapper that detects interactive SSH sessions, base64-encodes the remote-init snippet, and injects it via `ssh -t host "eval $(echo <b64> | base64 -d); exec $SHELL -li"`
3. Writes `~/.exterm/shell-integration/bin/docker` — same pattern for `docker exec` sessions
4. Prepends the bin dir to `PATH` so wrappers shadow the real binaries

**Non-interactive bypass**: The wrappers detect if a remote command is given (e.g. `ssh host ls`) and skip injection, passing through to the real binary directly.

**Remote init snippet**: `printf '\033]7;kitty-shell-cwd://<hostname><pwd>\a'` — the same OSC 7 format Ghostty's own integration uses (kitty-shell-cwd scheme). Registered via `add-zsh-hook chpwd` for zsh, `PROMPT_COMMAND` for bash.

#### Config
`applyExtermSettings(to:)` writes Exterm's theme/font/behavior settings to a temp Ghostty config file and loads it via `ghostty_config_load_file`. Note: `ghostty_config_load_default_files` also loads the user's own Ghostty config (`~/Library/Application Support/com.mitchellh.ghostty/config`).

### Key Design Decisions
- **TerminalBackend protocol**: Abstracts VT100Terminal so it can be swapped
- **libghostty-vt status**: Evaluated but not usable yet — C API has no per-cell screen access. Ghostty's own renderer uses internal Zig structs directly. Our VT100Terminal handles rendering with full TUI support (mouse, cursor visibility, app modes, bracketed paste). Ghostty kept as vendor dep for future integration.
- **Per-pane tabs**: Each split pane owns its own tab bar and terminal sessions
- **Workspace → SplitTree → Panes → Tabs**: Workspaces are folders, panes are splits, tabs are terminal sessions
- **TerminalSession detach/reattach**: Sessions survive view hierarchy rebuilds via `attachToView()`/`detachFromView()`
- **Thread safety**: VT100Terminal uses NSLock; `snapshot()` captures state under one lock for rendering
- **All UI callbacks must be on main thread**: PTY read loop is on background GCD queue; OSC callbacks dispatch to main

### Theming
- `TerminalTheme` defines foreground, background, 16 ANSI colors, selection, cursor, and all UI chrome colors
- 14 built-in themes (Default Dark, Tokyo Night, Catppuccin x4, Solarized x2, Dracula, Nord, Gruvbox, One Dark, Rosé Pine, Kanagawa)
- Theme colors are read at draw time from `AppSettings.shared.theme`
- `SettingsObserver` (ObservableObject) triggers SwiftUI re-renders on settings change

### Remote Explorer

**Detection**: Remote sessions are detected via two mechanisms:
1. **Title heuristics** (`TerminalBridge.detectRemoteFromHeuristics`) — triggered on every `GHOSTTY_ACTION_SET_TITLE`. Checks if the terminal title contains `user@host` (SSH) or `docker exec/run` patterns, AND the reported CWD doesn't exist locally. This is the primary detection path since remote shells don't have Ghostty's shell integration.
2. **Process tree** (`RemoteExplorer.detectRemoteSession`) — uses `proc_listchildpids` + `proc_name` syscalls to find ssh/docker child processes and parse their command-line args via `sysctl(KERN_PROCARGS2)`.

**Flow**: `paneView(_:titleChanged:)` in MainWindowController → `detectRemoteFromHeuristics` → if remote detected → `handleRemoteSessionChange` → switches sidebar to `RemoteFileTreeView` → `RemoteExplorer.listRemoteDirectory`.

**Remote commands**: Executed via `ssh -n -o BatchMode=yes <host> <cmd>` or `docker exec <container> sh -c <cmd>`. SSH prefers ControlMaster sockets when available (searched in `~/.ssh/`, `/tmp/`).

**Remote CWD tracking**: The SSH/Docker wrappers in `~/.exterm/shell-integration/bin/` inject an OSC 7 reporter into remote shells (see "Remote Shell Integration" above). When the remote shell has bash or zsh, `cd` triggers OSC 7 which flows back through the PTY to Ghostty's action callback, updating the explorer. For shells without PROMPT_COMMAND/chpwd support (dash, sh), only the initial CWD is reported.

- `RemoteSessionType` enum (.ssh, .docker) drives all remote behavior
- `RemoteExplorer` handles ControlMaster setup, remote file listing, remote CWD queries

### Plugin Architecture

#### Sidebar Plugins (`SidebarPlugin` protocol)
Sidebar panels below the file tree are registered as plugins. To add a new sidebar panel:
1. Create a class conforming to `SidebarPlugin` in `Exterm/Services/`
2. Implement `id`, `displayName`, `isAvailable`, `makeView(context:)`
3. Optionally implement `makeStatusBarSegment()` to provide a toggle icon in the status bar
4. Optionally implement `onAvailabilityChanged` for async availability (e.g. remote Docker check)
5. Register it in `MainWindowController.init()` via `registerSidebarPlugin()`
6. The panel auto-shows when `isAvailable` returns true; toggling adds/removes the view without rebuilding the file tree

Existing plugins:
- `DockerSidebarPlugin` — Docker container panel with live updates. Owns `DockerIconSegment` status bar toggle. Disabled on remote terminals (local only).
- `BookmarksSidebarPlugin` — Bookmarked directories panel. Works on both local and remote terminals. Auto-shows when bookmarks exist.

#### Status Bar Plugins (`StatusBarPlugin` protocol)
Status bar segments are registered as plugins. Sidebar plugins can provide their own segments via `makeStatusBarSegment()`. To add a standalone segment:
1. Create a class conforming to `StatusBarPlugin`
2. Set `position` (.left or .right) and `priority` (lower = closer to edge)
3. Implement `isVisible`, `draw`, `handleClick`
4. Register in `StatusBarView.registerDefaultPlugins()`

Existing segments: `GitBranchSegment`, `PathSegment`, `ProcessSegment`, `PaneInfoSegment`, `TimeSegment`, `BookmarkIconSegment`. Sidebar-owned: `DockerIconSegment`.

### Common Patterns
- `TerminalColor.cgColor` / `.nsColor` extensions for color conversion
- `AppSettings` uses `enum K` for UserDefaults keys, `bool(_:default:)` helper
- `shellEscape()` and `fileIcon(for:)` are shared free functions in `Services/`
- `NotificationCenter` with `.settingsChanged` for cross-component settings updates
- Font cache in TerminalView for bold/italic variants (hot path optimization)

## Guidelines
- Keep the zero-warnings build
- All AppKit UI operations must be on the main thread
- Use `TerminalColor` extensions instead of inline `CGFloat(r)/255` conversions
- Settings changes go through `AppSettings.shared` which auto-notifies
- Don't commit co-authored-by lines
