# Boo

<img width="451" height="451" alt="Rectangle 1392" src="https://github.com/user-attachments/assets/f9c18574-d6fe-4ba4-bc2c-ca2c3f17e423" />

A macOS terminal emulator with integrated file explorer, workspace management, split panes, and remote session support. Powered by [Ghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and Metal GPU rendering.

## Screenshots

_Coming soon_

## Features

- **Workspaces** — Open folders as workspaces with their own file tree (Cmd+N)
- **Per-pane tabs** — Each split pane has its own tab bar (Cmd+T)
- **Split panes** — Split right (Cmd+D) or down (Cmd+Shift+D)
- **File explorer** — Live-updating sidebar with file tree (Cmd+B to toggle)
- **32 color themes** — Catppuccin (all 4), Tokyo Night, Dracula, Nord, Solarized (dark/light), Gruvbox (dark/light), One Dark/Light, Rosé Pine, Kanagawa, Everforest (dark/light), GitHub (dark/light), Ayu (dark/light), Cobalt2, Horizon Dark, Material (dark/light), Monokai, Moonlight, Night Owl, Palenight, Synthwave '84, Default (dark/light)
- **Custom themes** — Create your own themes with a full color picker editor
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
- **IPC socket** — Unix socket at `~/.boo/boo.sock` for reliable process detection and plugin commands
- **Debug plugin** — Live event log and terminal state inspector for diagnostics

## Install

Download the latest release from [GitHub Releases](https://github.com/ph1p/boo/releases) — open the DMG and drag Boo to Applications.

## Build from Source

### Prerequisites

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Zig 0.15+** — `brew install zig`
- **Metal Toolchain** — `xcodebuild -downloadComponent MetalToolchain` (if not already installed)

### Quick Start

```bash
git clone --recursive https://github.com/ph1p/boo.git
cd boo
make setup    # Builds GhosttyKit + Boo
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
| `make clean`   | Clean build artifacts                                      |
| `make clean-ghostty` | Clean GhosttyKit build (for rebuild)                 |
| `make ghostty` | Build GhosttyKit only                                      |

## Keyboard Shortcuts

| Shortcut        | Action                               |
| --------------- | ------------------------------------ |
| **Cmd+N**       | New workspace (home directory)       |
| **Cmd+1-9**     | Switch to workspace N                |
| **Cmd+Shift+O** | Open folder as workspace             |
| **Cmd+T**       | New tab in active pane               |
| **Cmd+Opt+1-9** | Switch to tab N in active pane       |
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
| **Cmd+Return**  | Toggle full screen                   |
| **Cmd+Ctrl+=**  | Equalize split sizes                 |
| **Cmd+Shift+B** | Bookmark current directory           |
| **Ctrl+1-9**    | Jump to bookmark N                   |
| **Cmd+,**       | Settings                             |

## Architecture

```
Boo/
  App/              AppDelegate, MainWindowController (+extensions), WindowStateCoordinator, AppStore
  Ghostty/          GhosttyRuntime (app singleton), GhosttyView (Metal surface), TerminalScrollView
  Terminal/         TerminalBackend (PTY lifecycle protocol)
  Models/           Workspace, Pane (+ TabState), SplitTree, AppSettings, Theme
  Plugin/           Core plugin framework (protocol, registry, runtime, DSL, watcher)
    ViewDSL/        DSL parser, renderer, elements, action handler
  Plugins/          One directory per plugin (FileTree/, RemoteExplorer/, Git/, AIAgent/, Docker/, Bookmarks/, SystemInfo/, Debug/)
  Views/            App-level views (PaneView, StatusBarView, ToolbarView, SettingsWindow, UpdateWindow, etc.)
  Services/         Shared infrastructure (TerminalBridge, RemoteExplorer, BooSocketServer, AutoUpdater, etc.)
CGhostty/           C module wrapping ghostty.h
CPTYHelper/         C helper for forkpty()
Vendor/ghostty/     Ghostty source (git clone)
```

### State Model

Three layers of state:

1. **Global** — `AppSettings` singleton (theme, font, layout, plugin settings)
2. **Per-tab** — `TabState` struct on each `Pane.Tab` (CWD, remote session, title, plugin UI state)
3. **Global Observable** — `AppStore` singleton projecting current context, theme, and sidebar state for SwiftUI views

`WindowStateCoordinator` manages state transitions between `TerminalBridge` (event parser), `TabState` (source of truth), and `PluginRegistry`. On tab switch, the coordinator saves/restores plugin sidebar state and updates the bridge snapshot. `MainWindowController` is a thin shell that delegates state management to the coordinator.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Boo App                                                          │
│                                                                     │
│  ┌─────────────┐   ┌──────────────────────────────────────────┐     │
│  │ AppSettings │   │ Workspace                                │     │
│  │ (singleton) │   │  └─ SplitTree                            │     │
│  │ theme, font │   │      ├─ Pane → Tab[] → TabState (SOT)   │     │
│  │ plugin cfg  │   │      └─ Pane → Tab[] → TabState          │     │
│  └──────┬──────┘   └──────────────────┬───────────────────────┘     │
│         │                             │                             │
│         v                             v                             │
│  ┌─────────────────────────────────────────────────────┐            │
│  │ WindowStateCoordinator                              │            │
│  │  • sync bridge → TabState                           │            │
│  │  • save/restore plugin UI state on tab switch       │            │
│  │  • build TerminalContext from TabState               │            │
│  └────────────┬──────────────────────┬─────────────────┘            │
│               │                      │                              │
│               v                      v                              │
│  ┌────────────────────┐   ┌──────────────────────┐                  │
│  │ TerminalBridge     │   │ PluginRuntime        │                  │
│  │ (event parser)     │   │ enrich → freeze →    │                  │
│  │ • title heuristics │   │ react → evaluate     │                  │
│  │ • remote detection │   │                      │                  │
│  │ • process tracking │   │ TerminalContext       │                  │
│  └────────┬───────────┘   │ (frozen, immutable)  │                  │
│           │               └──────────┬───────────┘                  │
│           │                          │                              │
│  ┌────────▼───────────┐              v                              │
│  │ GhosttyRuntime     │   ┌──────────────────────────────────┐      │
│  │ GhosttyView        │   │ Plugins                          │      │
│  │ (Metal surface)    │   │ FileTree  Git      AIAgent       │      │
│  │                    │   │ Remote    Docker   Bookmarks     │      │
│  │ OSC 7 (CWD)       │   │ System    Debug    [External]    │      │
│  │ OSC 2 (title)      │   └──────────────────────────────────┘      │
│  │ process exit       │                                             │
│  └────────┬───────────┘                                             │
│           │                                                         │
│  ┌────────▼───────────┐   ┌──────────────────────────────────┐      │
│  │ PTY (CPTYHelper)   │   │ BooSocketServer               │      │
│  │ forkpty() + GCD    │   │ ~/.boo/boo.sock            │      │
│  │ background I/O     │   │ process registration (IPC)       │      │
│  └────────────────────┘   └──────────────────────────────────┘      │
│                                       ▲                             │
└───────────────────────────────────────┼─────────────────────────────┘
                                        │ Unix socket
                              ┌─────────┴──────────┐
                              │ Child processes     │
                              │ (AI agents, tools)  │
                              └────────────────────┘
```

**Event flow:**
```
Ghostty OSC → PaneView → MainWindowController → TerminalBridge (heuristics)
  → coordinator.syncBridgeToTab() → TabState
  → coordinator.buildContext() → TerminalContext (immutable) → Plugins
```

### Terminal Engine

Boo uses **GhosttyKit** — the same terminal engine that powers the [Ghostty terminal](https://ghostty.org). This provides:

- Complete VT/xterm escape sequence parsing
- Metal GPU-accelerated rendering
- Proper font shaping and text rendering
- Kitty keyboard protocol
- Mouse tracking (all modes)
- Scrollback with reflow
- TUI application support (vim, lazygit, htop, etc.)

### File Explorer

- **Local**: Uses FSEvents for live file system watching. Flattened lazy rendering handles large directories efficiently (separate `file-tree-local` plugin, visible in local sessions)
- **Remote SSH**: Auto-detects SSH sessions, lists files via `ssh <host> ls -1AF`. Boo manages its own SSH ControlMaster sockets — no user SSH config changes required (separate `file-tree-remote` plugin, visible in SSH/MOSH sessions)
- **Remote cd**: Clicking a directory in the remote tree runs `cd` in the active terminal. Tilde paths (`~`) are resolved to absolute paths so navigation works on Linux and macOS
- **Context menu**: Grouped by section — Terminal (cd, cat, paste path), OS (open in tab/pane, default app, reveal in Finder, copy path), Edit (new folder, rename, move to trash)

## IPC Socket

Boo exposes a Unix domain socket (`~/.boo/boo.sock`) as the primary communication layer between terminal child processes and the app. The socket path is available in all terminal sessions via `$BOO_SOCK`. Protocol: newline-delimited JSON — send a command, get a JSON response.

### Command Reference

| Category | Command | Description |
|----------|---------|-------------|
| **Process** | `set_status` | Register a process (pid, name, category, metadata) |
| | `clear_status` | Unregister a process |
| | `list_status` | List all registered processes |
| **Query** | `get_context` | Current terminal context (pane_id, CWD, git, process, remote) |
| | `get_theme` | Current theme name and dark/light mode |
| | `get_settings` | App settings snapshot |
| | `list_themes` | All available theme names |
| | `get_workspaces` | List workspaces with active state |
| **Control** | `set_theme` | Change theme (`name` parameter) |
| | `toggle_sidebar` | Toggle sidebar visibility |
| | `switch_workspace` | Switch workspace by `index` or `id` |
| | `new_tab` | Open new tab (optional `cwd`) |
| | `new_workspace` | Open new workspace (optional `path`) |
| | `send_text` | Write text to the active terminal |
| **Events** | `subscribe` | Subscribe to push events (`events` array) |
| | `unsubscribe` | Remove event subscriptions |
| **Status Bar** | `statusbar.set` | Push an external status bar segment |
| | `statusbar.clear` | Remove an external segment |
| | `statusbar.list` | List external segments |
| **Plugin** | `<namespace>.<action>` | Route to a plugin's registered handler |

### Usage Examples

```bash
# Register as an AI agent
echo '{"cmd":"set_status","pid":'"$$"',"name":"claude","category":"ai"}' \
  | nc -U "$BOO_SOCK"

# Query current terminal context
echo '{"cmd":"get_context"}' | nc -U "$BOO_SOCK"

# Change theme
echo '{"cmd":"set_theme","name":"Tokyo Night"}' | nc -U "$BOO_SOCK"

# Push a status bar segment
echo '{"cmd":"statusbar.set","id":"ci","text":"CI: passing","icon":"checkmark.circle","tint":"green"}' \
  | nc -U "$BOO_SOCK"

# Subscribe to events (keep connection open for push notifications)
echo '{"cmd":"subscribe","events":["cwd_changed","process_changed"]}' | nc -U "$BOO_SOCK"
# → receives: {"event":"cwd_changed","data":{"path":"/new/dir","is_remote":false,"pane_id":"..."}}
```

### Event Subscriptions

Subscribe to real-time push events by keeping a socket connection open:

| Event | Data |
|-------|------|
| `cwd_changed` | `path`, `is_remote`, `pane_id` |
| `title_changed` | `title`, `pane_id` |
| `process_changed` | `name`, `category`, `pane_id` |
| `remote_session_changed` | `type`, `host`, `active`, `pane_id` |
| `focus_changed` | `pane_id` |
| `workspace_switched` | `workspace_id` |
| `theme_changed` | `name`, `is_dark` |
| `settings_changed` | `topic` |

All terminal-scoped events include a `pane_id` field identifying which pane the event originated from. This allows subscribers to filter events by pane and avoid cross-pane interference in split-view setups.

Use `"events": ["*"]` to subscribe to all events.

### External Status Bar Segments

External processes can push custom segments to the status bar. Segments are automatically cleaned up when the client disconnects.

```bash
# Show build status
echo '{"cmd":"statusbar.set","id":"build","text":"Building...","icon":"hammer","tint":"yellow","position":"left","priority":30}' \
  | nc -U "$BOO_SOCK"

# Clear when done
echo '{"cmd":"statusbar.clear","id":"build"}' | nc -U "$BOO_SOCK"
```

Tint colors: `red`, `green`, `yellow`, `blue`, `orange`, `purple`, `accent`, or `#hex`.

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
- **Auto-cleanup**: dead PIDs swept every 5s; disconnected clients' segments and subscriptions auto-removed
- **Resource limits**: max 128 concurrent clients, 64KB buffer cap per connection, non-blocking accept

### Plugin Commands

Plugins can register custom socket command handlers:

```swift
BooSocketServer.shared.registerHandler(namespace: "git") { json in
    // Handle {"cmd":"git.refresh"} etc.
    return ["ok": true, "branch": "main"]
}
```

External tools can then send plugin-specific commands:
```bash
echo '{"cmd":"git.refresh"}' | nc -U "$BOO_SOCK"
```

## Plugin System

Boo has an extensible plugin system. Plugins provide sidebar panels, status bar segments, and respond to terminal lifecycle events.

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

Drop a folder into `~/.boo/plugins/` with a `plugin.json` manifest and a `main.js`. Plugins are hot-loaded — no restart required.

```
~/.boo/plugins/my-plugin/
  plugin.json       # Required manifest
  main.js           # Plugin logic
```

#### Writing a Plugin

Your `render` function receives the terminal context and returns DSL elements. Runs in JavaScriptCore — no process spawn, no dependencies.

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "icon": "star",
  "description": "Example plugin",
  "runtime": "js",
  "capabilities": { "sidebarPanel": true }
}
```

```javascript
function render(ctx) {
  var raw = readFile("package.json");
  if (!raw) return { type: "label", text: "No package.json", style: "muted" };

  var pkg = JSON.parse(raw);
  var names = Object.keys(pkg.scripts || {});

  return {
    type: "list",
    items: names.map(function (name) {
      return { label: name, icon: "play.circle", action: { type: "exec", command: "npm run " + name } };
    })
  };
}
```

Plugins have access to `readFile(path)` and `fileExists(path)` for reading files relative to the current directory. The full terminal context is available via `ctx` (cwd, git, process, remote session, settings, etc.). Plugin settings declared in the manifest are available via `ctx.settings`.

#### Context Menus

List items and buttons support right-click context menus:

```javascript
{
  label: "src/index.ts", icon: "doc",
  action: { type: "open", path: "src/index.ts" },
  contextMenu: [
    { label: "Copy Path", icon: "doc.on.doc", action: { type: "copy", path: "src/index.ts" } },
    { label: "Reveal in Finder", icon: "folder", action: { type: "reveal", path: "src/index.ts" } },
    { label: "Delete", icon: "trash", style: "destructive", action: { type: "exec", command: "rm src/index.ts" } }
  ]
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
| `"env.local"`                      | Only in local sessions         |
| `"env.ssh"`                        | Only in SSH/MOSH sessions      |
| `"env.docker"`                     | Only in Docker sessions        |

See `examples/plugins/` for five working examples. Start with **hello-world**, then study **node-project** or **terminal-inspector** for the full plugin API.

### Developing a Built-in Plugin

1. Create `Boo/Plugins/YourPlugin/YourPlugin.swift`
2. Conform to `BooPluginProtocol` — implement `pluginID`, `manifest`, and whichever UI/lifecycle methods you need
3. Put views and services in the same directory
4. Use `hostActions` for terminal interaction (paste path, open tab/pane, send raw text)
5. Call `onRequestCycleRerun?()` when your plugin's data changes and the sidebar/status bar should refresh
6. Register in `PluginRegistry.registerBuiltins()`
7. Add tests in `Tests/BooTests/Plugins/YourPlugin/`

No `Package.swift` changes needed — SPM resolves recursively within the target directories.

#### Event Subscriptions

Plugins declare which events they need. The registry only delivers callbacks for subscribed events:

```swift
// Only receive CWD and focus — skip process, remote, terminal lifecycle
var subscribedEvents: Set<PluginEvent> { [.cwdChanged, .focusChanged] }
```

Available: `.cwdChanged`, `.processChanged`, `.remoteSessionChanged`, `.focusChanged`, `.terminalCreated`, `.terminalClosed`, `.remoteDirectoryListed`. Default is all events.

See [AGENTS.md](AGENTS.md) for detailed protocol reference and architecture.

## Auto-Update

Boo checks GitHub Releases for new versions on launch (once every 24 hours). You can also check manually via the app menu: **Boo → Check for Updates...**

The update flow: download DMG → verify code signature → replace app → relaunch. Settings:
- Auto-check can be disabled in preferences
- Individual versions can be skipped

Releases are automated via [semantic-release](https://github.com/semantic-release/semantic-release) — conventional commits on `main` trigger version bumps, builds, and GitHub Releases.

## Settings

Open with **Cmd+,**. Organized in tabs:

- **General** — Auto-update preferences
- **Theme** — 32 built-in color themes with live preview swatches, custom theme editor
- **Terminal** — Font, font size, cursor style (block/beam/underline/outline)
- **Explorer** — Font, font size, show header/icons/hidden files
- **Status Bar** — Toggle git branch, path, running process, pane count, clock
- **Layout** — Sidebar width, pane divider style
- **Plugins** — Enable/disable plugins, per-plugin settings
- **Shortcuts** — Reference of all keyboard shortcuts

## Tests

```bash
swift test
```

717 tests covering models, themes, plugins, terminal bridge, remote explorer, SSH control manager, sidebar layout, accessibility, E2E plugin lifecycle, split/workspace operations, IPC socket protocol, process detection, event subscriptions, JSC runtime, DSL parsing, and script plugin adapters.

## License

MIT
