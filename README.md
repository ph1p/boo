# Exterm - Explorer Terminal

A macOS terminal emulator with integrated file explorer, workspace management, split panes, and remote session support. Powered by [Ghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and Metal GPU rendering.

## Screenshots

_Coming soon_

## Features

- **Workspaces** — Open folders as workspaces with their own file tree (Cmd+N)
- **Per-pane tabs** — Each split pane has its own tab bar (Cmd+T)
- **Split panes** — Split right (Cmd+D) or down (Cmd+Shift+D)
- **File explorer** — Live-updating sidebar with file tree (Cmd+B to toggle)
- **14 color themes** — Catppuccin (all 4), Tokyo Night, Dracula, Nord, Solarized, Gruvbox, One Dark, Rosé Pine, Kanagawa
- **AI agent monitor** — Auto-detects Claude, Codex, Aider, Cursor, Copilot sessions with config/diff overview
- **Remote explorer** — Auto-detects SSH sessions, shows remote file tree
- **Git integration** — Branch name in status bar, clickable branch switcher with local + remote branches
- **Running process** — Status bar shows the foreground process (zsh, node, vim, etc.)
- **Customizable** — Font, cursor style, status bar segments, explorer settings
- **Workspace colors** — Preset or custom colors per workspace, pinning, renaming
- **Undo** — Cmd+Z reopens closed tabs and panes
- **Mouse selection** — Click, double-click (word), triple-click (line)
- **Auto-updater** — Checks GitHub Releases for new versions, downloads and installs updates
- **Focus memory** — Remembers last focused pane per workspace, restores on switch
- **IPC socket** — Unix socket at `~/.exterm/exterm.sock` for reliable process detection and plugin commands
- **Debug plugin** — Live event log and terminal state inspector for diagnostics

## Install

Download the latest release from [GitHub Releases](https://github.com/ph1p/exterm/releases) — open the DMG and drag Exterm to Applications.

## Build from Source

### Prerequisites

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Zig 0.15+** — `brew install zig`
- **Metal Toolchain** — `xcodebuild -downloadComponent MetalToolchain` (if not already installed)

### Quick Start

```bash
git clone --recursive https://github.com/ph1p/exterm.git
cd exterm
make setup    # Builds GhosttyKit + Exterm
make run      # Build and launch
```

### Make Targets

| Target         | Description                                                |
| -------------- | ---------------------------------------------------------- |
| `make setup`   | First-time setup (init submodule + build everything)       |
| `make build`   | Debug build                                                |
| `make run`     | Build and launch                                           |
| `make release` | Optimized release build                                    |
| `make test`    | Run all tests                                              |
| `make app`     | Create `.app` bundle from release build                    |
| `make dmg`     | Create distributable DMG                                   |
| `make dist`    | Full release pipeline (build, bundle, sign, notarize, DMG) |
| `make lint`    | Check code style with swift-format                         |
| `make format`  | Format source code in-place                                |

## Keyboard Shortcuts

| Shortcut        | Action                               |
| --------------- | ------------------------------------ |
| **Cmd+N**       | New workspace (home directory)       |
| **Cmd+Shift+O** | Open folder as workspace             |
| **Cmd+T**       | New tab in active pane               |
| **Cmd+W**       | Smart close (tab → pane → workspace) |
| **Cmd+Z**       | Reopen closed tab/pane               |
| **Cmd+Shift+W** | Close pane                           |
| **Cmd+D**       | Split right                          |
| **Cmd+Shift+D** | Split down                           |
| **Cmd+]**       | Focus next pane                      |
| **Cmd+[**       | Focus previous pane                  |
| **Cmd+B**       | Toggle file explorer                 |
| **Cmd+K**       | Clear screen                         |
| **Cmd+Shift+K** | Clear scrollback                     |
| **Cmd++**       | Increase font size                   |
| **Cmd+-**       | Decrease font size                   |
| **Cmd+0**       | Reset font size                      |
| **Cmd+C**       | Copy selection                       |
| **Cmd+V**       | Paste                                |
| **Cmd+A**       | Select all                           |
| **Cmd+,**       | Settings                             |

## Architecture

```
Exterm/
  App/              AppDelegate, MainWindowController, WindowStateCoordinator
  Ghostty/          GhosttyRuntime (app singleton), GhosttyView (Metal surface)
  Terminal/         TerminalBackend (PTY lifecycle)
  Models/           Workspace, Pane (+ TabState), SplitTree, AppSettings, Theme
  Plugin/           Core plugin framework (protocol, registry, runtime, DSL)
  Plugins/          One directory per plugin (FileTree/, RemoteExplorer/, Git/, AIAgent/, Docker/, Bookmarks/, SystemInfo/, Debug/)
  Views/            App-level views (ToolbarView, PaneView, StatusBarView, SettingsWindow)
  Services/         Shared infrastructure (ExtermSocketServer, FileSystemWatcher, RemoteExplorer, TerminalBridge, AutoUpdater)
CGhostty/           C module wrapping ghostty.h
CPTYHelper/         C helper for forkpty()
Vendor/ghostty/     Ghostty source (git clone)
```

### State Model

Two layers of state:

1. **Global** — `AppSettings` singleton (theme, font, layout)
2. **Per-tab** — `TabState` struct on each `Pane.Tab` (CWD, remote session, title, plugin UI state)

`WindowStateCoordinator` manages state transitions between `TerminalBridge` (event parser), `TabState` (source of truth), and `PluginRegistry`. On tab switch, the coordinator saves/restores plugin sidebar state and updates the bridge snapshot. `MainWindowController` is a thin shell that delegates state management to the coordinator.

```
Ghostty OSC → PaneView → MainWindowController → TerminalBridge (heuristics)
  → coordinator.syncBridgeToTab() → TabState
  → coordinator.buildContext() → TerminalContext (immutable) → Plugins
```

### Terminal Engine

Exterm uses **GhosttyKit** — the same terminal engine that powers the [Ghostty terminal](https://ghostty.org). This provides:

- Complete VT/xterm escape sequence parsing
- Metal GPU-accelerated rendering
- Proper font shaping and text rendering
- Kitty keyboard protocol
- Mouse tracking (all modes)
- Scrollback with reflow
- TUI application support (vim, lazygit, htop, etc.)

### File Explorer

- **Local**: Uses FSEvents for live file system watching. Flattened lazy rendering handles large directories efficiently (separate `file-tree-local` plugin, visible in local sessions)
- **Remote SSH**: Auto-detects SSH sessions, lists files via `ssh <host> ls -1AF`. Exterm manages its own SSH ControlMaster sockets — no user SSH config changes required (separate `file-tree-remote` plugin, visible in SSH/MOSH sessions)
- **Remote cd**: Clicking a directory in the remote tree runs `cd` in the active terminal. Tilde paths (`~`) are resolved to absolute paths so navigation works on Linux and macOS
- **Context menu**: Grouped by section — Terminal (cd, cat, paste path), OS (open in tab/pane, default app, reveal in Finder, copy path), Edit (new folder, rename, move to trash)

## IPC Socket

Exterm exposes a Unix domain socket for reliable communication between terminal child processes and the app. AI agents, build tools, test runners, and custom scripts use it to register themselves so Exterm can track them accurately — independent of terminal title heuristics.

### How It Works

```
Shell process (zsh)
  └─ AI Agent (claude)
       │
       ├─ Reads $EXTERM_SOCK env var
       ├─ Connects to ~/.exterm/exterm.sock
       └─ Sends: {"cmd":"set_status","pid":12345,"name":"claude","category":"ai"}
                                    │
                              ExtermSocketServer
                                    │
                              TerminalBridge picks up "claude"
                              as the foreground process
                                    │
                              Plugins react (AI Agent panel, status bar, etc.)
                                    │
                              When agent exits:
                              kill(pid, 0) → ESRCH → auto-cleared
```

### Usage

The socket path is available in all terminal sessions via `$EXTERM_SOCK`:

```bash
# Register as an AI agent
echo '{"cmd":"set_status","pid":'"$$"',"name":"claude","category":"ai"}' \
  | nc -U "$EXTERM_SOCK"

# Register as a build tool with metadata
echo '{"cmd":"set_status","pid":'"$$"',"name":"webpack","category":"build","metadata":{"mode":"dev"}}' \
  | nc -U "$EXTERM_SOCK"

# Unregister (or just exit — dead PIDs are auto-swept every 5s)
echo '{"cmd":"clear_status","pid":'"$$"'}' | nc -U "$EXTERM_SOCK"

# List all registered processes
echo '{"cmd":"list_status"}' | nc -U "$EXTERM_SOCK"
```

### Process Detection Priority

| Priority | Source | When used |
|----------|--------|-----------|
| 1st | Socket registration | A process sent `set_status` and is still alive |
| 2nd | Terminal title | No socket registration — parse process name from title |

Socket-registered processes **always override** title-based detection. They survive all title changes (paths, spinners, shell names). When the process dies, `kill(pid, 0)` detects it within 5 seconds and clears the registration automatically.

### Reliability & Security

- **Thread-safe**: all socket I/O on a dedicated serial queue; public accessors use synchronized snapshots
- **Peer authentication**: `LOCAL_PEERCRED` verifies every connecting process belongs to the same user
- **Ancestor verification**: registered PIDs are verified as descendants of the shell via `sysctl(KERN_PROC)` — prevents cross-tab interference
- **Auto-cleanup**: dead PIDs swept every 5s; no manual unregistration needed
- **Resource limits**: max 64 concurrent clients, 16KB buffer cap per connection, non-blocking accept

### Plugin Commands

Plugins can register custom socket command handlers:

```swift
ExtermSocketServer.shared.registerHandler(namespace: "git") { json in
    // Handle {"cmd":"git.refresh"} etc.
    return ["ok": true, "branch": "main"]
}
```

External tools can then send plugin-specific commands:
```bash
echo '{"cmd":"git.refresh"}' | nc -U "$EXTERM_SOCK"
```

## Plugin System

Exterm has an extensible plugin system. Plugins provide sidebar panels, status bar segments, and respond to terminal lifecycle events.

### Built-in Plugins

| Plugin             | Directory                  | Description                                                          |
| ------------------ | -------------------------- | -------------------------------------------------------------------- |
| **Files (Local)**  | `Plugins/FileTree/`        | Local file explorer with FSEvents watching (visible in local sessions) |
| **Files (Remote)** | `Plugins/RemoteExplorer/`  | Remote file explorer for SSH/MOSH sessions                           |
| **Git**            | `Plugins/Git/`             | Branch, status, staged/unstaged/untracked files, stash, ahead/behind |
| **AI Agent**       | `Plugins/AIAgent/`         | Monitors AI coding agents (Claude, Codex, Aider, Cursor, Copilot)   |
| **Docker**         | `Plugins/Docker/`          | Running container list with exec, logs, start/stop/restart actions   |
| **Bookmarks**      | `Plugins/Bookmarks/`       | Saved directory bookmarks with per-host namespacing                  |
| **System**         | `Plugins/SystemInfo/`      | CPU load, memory, disk usage (example plugin demonstrating all patterns) |
| **Debug**          | `Plugins/Debug/`           | Logs all lifecycle events with timestamps, live terminal state inspector |

### External Plugins

Drop a folder into `~/.exterm/plugins/` with a `plugin.json` manifest and a script. Plugins are hot-loaded — no restart required.

```
~/.exterm/plugins/my-plugin/
  plugin.json       # Required manifest
  main.sh           # Shell script (or main.js for JavaScript)
```

#### Minimal `plugin.json`

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "icon": "star",
  "description": "Example plugin",
  "when": null,
  "capabilities": { "sidebarPanel": true, "statusBarSegment": true },
  "statusBar": { "position": "right", "priority": 30 }
}
```

#### When-Clauses

Control when your plugin is visible:

| Expression                         | Meaning                        |
| ---------------------------------- | ------------------------------ |
| `null`                             | Always visible                 |
| `"git.active"`                     | Only in git repos              |
| `"!remote"`                        | Only in local sessions         |
| `"remote"`                         | Only in remote sessions        |
| `"remote.type == 'ssh'"`           | Only in SSH sessions           |
| `"git.active && !remote"`          | Git repos, local only          |
| `"process.name == 'vim'"`          | Only when vim is running       |
| `"process.editor"`                 | Only when any editor is active |
| `"process.category == 'database'"` | Only for database clients      |
| `"process.ai"`                     | Only when an AI agent is active |
| `"env.ssh"`                        | Only in SSH/MOSH sessions      |

#### Script Environment

Scripts receive terminal context via environment variables:

| Variable               | Example               |
| ---------------------- | --------------------- |
| `EXTERM_CWD`           | `/Users/phlp/project` |
| `EXTERM_PROCESS`       | `node`                |
| `EXTERM_GIT_BRANCH`    | `main`                |
| `EXTERM_GIT_REPO_ROOT` | `/Users/phlp/project` |
| `EXTERM_REMOTE_TYPE`   | `ssh`                 |
| `EXTERM_REMOTE_HOST`   | `server.example.com`  |
| `EXTERM_PANE_COUNT`    | `2`                   |
| `EXTERM_TAB_COUNT`     | `3`                   |

Scripts output JSON DSL to stdout. Example:

```json
[
  { "type": "text", "content": "Hello from my plugin", "style": "bold" },
  { "type": "button", "label": "Run tests", "action": { "type": "exec", "command": "make test" } }
]
```

#### JavaScript Plugins

Set `"runtime": "js"` in the manifest and provide `main.js`. Runs in JavaScriptCore — no shell overhead:

```javascript
function render(context) {
  return JSON.stringify([{ type: "text", content: "Branch: " + context.git.branch }]);
}
```

### Developing a Built-in Plugin

1. Create `Exterm/Plugins/YourPlugin/YourPlugin.swift`
2. Conform to `ExtermPluginProtocol` — implement `pluginID`, `manifest`, and whichever UI/lifecycle methods you need
3. Put views and services in the same directory
4. Use `hostActions` for terminal interaction (paste path, open tab/pane, send raw text)
5. Call `onRequestCycleRerun?()` when your plugin's data changes and the sidebar/status bar should refresh
6. Register in `PluginRegistry.registerBuiltins()`
7. Add tests in `Tests/ExtermTests/Plugins/YourPlugin/`

No `Package.swift` changes needed — SPM resolves recursively within the target directories.

See [AGENTS.md](AGENTS.md) for detailed protocol reference and architecture.

## Auto-Update

Exterm checks GitHub Releases for new versions on launch (once every 24 hours). You can also check manually via the app menu: **Exterm → Check for Updates...**

The update flow: download DMG → verify code signature → replace app → relaunch. Settings:
- Auto-check can be disabled in preferences
- Individual versions can be skipped

Releases are automated via [semantic-release](https://github.com/semantic-release/semantic-release) — conventional commits on `main` trigger version bumps, builds, and GitHub Releases.

## Settings

Open with **Cmd+,**. Organized in tabs:

- **Theme** — 14 color themes with live preview swatches
- **Terminal** — Font, font size, cursor style (block/beam/underline/outline)
- **Explorer** — Font, font size, show header/icons/hidden files
- **Status Bar** — Toggle git branch, path, running process, pane count, clock
- **Shortcuts** — Reference of all keyboard shortcuts

## Tests

```bash
swift test
```

656 tests covering models, themes, plugins, terminal bridge, remote explorer, SSH control manager, sidebar layout, accessibility, E2E plugin lifecycle, split/workspace operations, IPC socket protocol, and process detection.

## License

MIT
