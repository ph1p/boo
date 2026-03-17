# Exterm - Explorer Terminal

A macOS terminal emulator with integrated file explorer, workspace management, and remote session support.

## Architecture

### Language & Frameworks
- **Swift** (macOS native, minimum macOS 13)
- **AppKit** for all terminal UI, toolbar, status bar, split panes
- **SwiftUI** for file tree sidebar and settings window only
- **CoreText** for terminal text rendering (NSView.draw)
- **POSIX PTY** via C helper (`CPTYHelper/`) using `forkpty()`

### Build
- Swift Package Manager (`Package.swift`)
- `make run` to build and launch
- `swift build` for build only
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

### Key Design Decisions
- **TerminalBackend protocol**: Abstracts VT100Terminal so it can be swapped (e.g., for libghostty-vt)
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
- Detects SSH and Docker exec sessions by polling the process tree (`pgrep`)
- Runs commands via `ssh <host> <cmd>` or `docker exec <container> sh -c <cmd>`
- Shows "Connecting..." state immediately, waits for auth grace period before attempting commands
- `RemoteSessionType` enum (.ssh, .docker) drives all remote behavior

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
