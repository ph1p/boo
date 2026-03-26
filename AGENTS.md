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
- **GhosttyKit**: Git submodule at `Vendor/ghostty`; build with `make ghostty` or `cd Vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast`
- **Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain` (if first time)
- `swift build` to build, `make run` to build and launch
- `make lint` / `make format` — swift-format linting and formatting (config in `.swift-format`)
- `make app` / `make dmg` / `make dist` — app bundle, DMG packaging, full release pipeline
- Zero warnings policy

### Project Structure
```
Exterm/
  App/              - AppDelegate, MainWindowController (+extensions), WindowStateCoordinator, AppStore
  Ghostty/          - GhosttyRuntime (app singleton), GhosttyView (Metal surface), TerminalScrollView
  Terminal/         - TerminalBackend (PTY lifecycle protocol)
  Models/           - Workspace, Pane (+ TabState), SplitTree, AppSettings, Theme
  Plugin/           - Core plugin framework (protocol, registry, runtime, DSL, watcher)
    ViewDSL/        - DSL parser, renderer, elements, action handler
  Plugins/          - One directory per plugin, all plugin-specific code colocated
    FileTree/       - LocalFileTreePlugin, FileTreeView, FileTreeNode
    RemoteExplorer/ - RemoteFileTreePlugin, RemoteFileTreeView, RemoteFileTreeNode
    Git/            - GitPlugin, GitDetailView, GitService
    AIAgent/        - AIAgentPlugin, AIAgentDetailView
    Docker/         - DockerPlugin, DockerService
    Bookmarks/      - BookmarksPlugin, BookmarksPanelView, BookmarkService
    SystemInfo/     - SystemInfoPlugin (reference example plugin)
    Debug/          - DebugPlugin (lifecycle event logger and state inspector)
  Views/            - App-level views only (PaneView, StatusBarView, ToolbarView, SettingsWindow, UpdateWindow, etc.)
  Services/         - Shared infrastructure (TerminalBridge, RemoteExplorer, ExtermSocketServer, AutoUpdater, FileSystemWatcher, ContextAnnouncementEngine, etc.)
CGhostty/           - C module wrapping ghostty.h
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

### State Architecture

Two-layer state model:

1. **Global State** — `AppSettings` (singleton): theme, font, layout, and per-plugin settings. Accessed via `AppSettings.shared`, notifies via `.settingsChanged`. Plugin-specific settings (e.g. git branch visibility, explorer font) are stored in a namespaced `pluginSettings` dictionary and accessed via `pluginBool()`/`pluginString()`/`pluginDouble()` helpers.

2. **Per-Terminal State** — `TabState` (struct on each `Pane.Tab`): working directory, remote session, shell PID, title, plugin UI state (open/expanded plugin IDs). Single source of truth per tab.

**Key types:**
- `TabState` (`Models/Pane.swift`) — per-tab state struct. `Pane.Tab` convenience accessors (`tab.title`, `tab.workingDirectory`) forward to `tab.state`.
- `WindowStateCoordinator` (`App/WindowStateCoordinator.swift`) — centralized state manager. Saves/restores per-tab plugin state on tab switch, syncs bridge → `TabState`, builds `TerminalContext` from `TabState`.
- `BridgeState` (`Services/TerminalBridge.swift`) — transient bridge snapshot (renamed from `TerminalState`). Not the source of truth — coordinator syncs detection results back to `TabState`.
- `TerminalContext` (`Plugin/TerminalContext.swift`) — frozen immutable snapshot passed to plugins. Built via `TerminalContext.build(tabState:...)` or `coordinator.buildContext()`.

**Data flow:**
```
Ghostty OSC event → PaneView delegate → MainWindowController
  → TerminalBridge (heuristics, remote detection)
  → coordinator.syncBridgeToTab() → writes to TabState
  → runPluginCycle() → coordinator.buildContext() → TerminalContext
  → PluginRuntime (enrich → freeze → react) → sidebar/status bar
```

**Tab switch flow:**
```
PaneView.activateTab() → didFocus delegate
  → coordinator.activateTab(tab, paneID:)
    → save plugin state to previous tab's TabState
    → restore new tab's TabState → openPluginIDs, expandedPluginIDs
    → bridge.restoreTabState() → update bridge snapshot
  → runPluginCycle() → rebuild sidebar
```

`MainWindowController` properties (`bridge`, `pluginRegistry`, `openPluginIDs`, `expandedPluginIDs`, `previousFocusedTabID`, `isRemoteSidebar`, `activeRemoteSession`) are computed proxies to the coordinator — no separate state tracking.

3. **Global Observable State** — `AppStore` (singleton, `@MainActor`): read-only projection of app-wide state for SwiftUI views. Published properties: `context` (current `TerminalContext`), `theme` (snapshot), `sidebarVisible`, `openPluginIDs`, `visiblePluginIDs`. Updated by `MainWindowController` at end of each plugin cycle. Uses `Equatable` guards to suppress spurious updates.

4. **Accessibility** — `ContextAnnouncementEngine`: composes VoiceOver announcements when terminal focus changes. Debounced to 0.2s, announces environment type, working directory, and git branch. Respects VoiceOver enabled state.

### Key Design Decisions
- **TerminalBackend protocol**: Abstracts PTY lifecycle so backends can be swapped
- **Per-pane tabs**: Each split pane owns its own tab bar and terminal sessions
- **Workspace → SplitTree → Panes → Tabs**: Workspaces are folders, panes are splits, tabs are terminal sessions
- **TabState as single source of truth**: All per-tab state (terminal + plugin UI) in one struct on `Pane.Tab` — eliminates scattered dictionaries and manual sync
- **WindowStateCoordinator**: Centralizes state transitions between bridge, tab model, and plugin registry
- **BridgeState is transient**: `TerminalBridge.BridgeState` is a working snapshot; coordinator syncs results back to `TabState`
- **TerminalSession detach/reattach**: Sessions survive view hierarchy rebuilds via `attachToView()`/`detachFromView()`
- **Thread safety**: All UI callbacks on main thread; PTY read loop is on background GCD queue; OSC callbacks dispatch to main

### Theming
- `TerminalTheme` defines foreground, background, 16 ANSI colors, selection, cursor, and all UI chrome colors
- 22 built-in themes (Default Dark, Tokyo Night, Catppuccin x4, Solarized x2, Dracula, Nord, Gruvbox x2, One Dark/Light, Rosé Pine, Kanagawa, Everforest x2, GitHub x2, Ayu x2)
- Theme colors are read at draw time from `AppSettings.shared.theme`
- `SettingsObserver` (ObservableObject) triggers SwiftUI re-renders on settings change

### Remote Explorer

**Detection**: Remote sessions are detected via two cooperating mechanisms:
1. **Title heuristics** (`TerminalBridge.detectRemoteFromHeuristics` / `detectRemoteFromProcessName`) — triggered on every `GHOSTTY_ACTION_SET_TITLE`. Detects `user@host` prompts (SSH) and `docker exec/run` commands in the terminal title.
2. **Process tree** (`RemoteExplorer.detectRemoteSessionFiltered`, polled by `RemoteSessionMonitor`) — uses `proc_listchildpids` + `proc_name` syscalls to find ssh/docker child processes and parse their command-line args via `sysctl(KERN_PROCARGS2)`. Authoritative for session end (no child = no session).

**Session reconciliation** (`TerminalBridge.resolveRemoteSession` + `reconcileWithProcessTree`):
- Title heuristics detect session start and extract `user@host` display info
- Process tree confirms the session and provides the SSH config alias (the actual argument to `ssh`, e.g., "het")
- `RemoteSessionType.ssh(host:alias:)` carries both: `host` for display/equality, `alias` for SSH command execution
- `sshConnectionTarget` returns alias when available, falling back to host — this is what `runSSH()`, `SSHControlManager`, and cache keys use
- Custom `Equatable` ignores alias (prevents false session transitions when alias is discovered)

**Session stability rules** (in `resolveRemoteSession`):
- Transient command titles ("cd /tmp", "vim file.txt") do NOT clear a remote session — only known local shell names ("zsh", "bash") or local `user@host` prompts clear it
- Docker sessions are not flipped to SSH by container prompts ("root@abc123:~")
- SSH alias is preserved across title changes (short alias like "het" stays stable even when title shows "root@ubuntu-server:/path")
- Process tree hint overrides title heuristics when the title returns nil but the process tree confirms a session

**Flow**: `paneView(_:titleChanged:)` → `TerminalBridge.handleTitleChange` → `resolveRemoteSession` (title-based) → tab model sync → `runPluginCycle` → `FileTreePlugin.makeDetailView` → `getOrCreateRemoteRoot` → `RemoteExplorer.listRemoteDirectory`.

**Remote commands**: Executed via `ssh -n -o BatchMode=yes <target> <cmd>` or `docker exec <container> sh -c <cmd>`. The SSH target is `session.sshConnectionTarget` (alias when available). SSH uses Exterm's managed ControlMaster sockets (`SSHControlManager`) when available, falling back to the user's own SSH config.

**Remote CWD tracking**: The SSH/Docker wrappers in `~/.exterm/shell-integration/bin/` inject an OSC 7 reporter into remote shells (see "Remote Shell Integration" above). When the remote shell has bash or zsh, `cd` triggers OSC 7 which flows back through the PTY to Ghostty's action callback, updating the explorer. For shells without PROMPT_COMMAND/chpwd support (dash, sh), only the initial CWD is reported. `remoteCwd` is also extracted from title prompts via `extractRemoteCwd` (e.g., "root@host:/tmp" → "/tmp").

**File tree cache** (`FileTreePlugin.getOrCreateRemoteRoot`):
- Cache key: `"{sshConnectionTarget}:{resolvedPath}"` — ensures alias-based keys match socket keys
- On `cd`: existing root is reused (host prefix match), `updatePath` resets retry/loading state, `loadChildren` fetches new listing
- `RemoteFileTreeNode.updatePath` cancels in-flight retries, resets `isLoading` and `retriesLeft` so the next load isn't blocked

#### File Tree Rendering

Both local and remote file trees use a **flat LazyVStack** architecture for performance with large directories. Instead of recursive `VStack` nesting (where child views are rendered eagerly), `flattenedRows()` walks the tree and produces a flat array of `(node, depth)` pairs. `LazyVStack` then virtualizes rows outside the viewport.

A `treeRevision` counter on the root node is incremented on any structural change (expand/collapse/children loaded). Child nodes hold a `weak var root` back-pointer to bump the counter. The root view reads `root.treeRevision` in its body to trigger re-flattening.

The sidebar's `NSScrollView` uses Auto Layout constraints (top/leading/trailing pins) on its `NSHostingView` document view — like CSS `overflow: auto`. This keeps the scroll content height in sync with SwiftUI content changes without manual `fittingSize` measurement.

- `RemoteSessionType` enum (`.ssh(host:alias:)`, `.docker(container:)`) drives all remote behavior
- `RemoteExplorer` handles remote file listing, remote CWD queries, and home path resolution (cache keyed on `sshConnectionTarget`)
- `SSHControlManager` manages per-session background SSH master connections with Exterm-owned sockets (no user config required)
- `RemoteSessionMonitor` polls process trees every 2s, fires `onSessionChanged` on transitions only

### Plugin Architecture

Exterm has two plugin systems:

1. **Built-in plugins** — Swift classes in `Exterm/Plugins/` conforming to `ExtermPluginProtocol`
2. **External plugins** — Folders in `~/.exterm/plugins/` with a `plugin.json` manifest and a `main.js` (recommended) or `main.sh`, hot-loaded by `PluginWatcher`

Both use the same protocol, lifecycle, and UI integration.

#### Directory Layout

All code for a single plugin lives in one directory under `Exterm/Plugins/`:

```
Exterm/Plugins/
  FileTree/           LocalFileTreePlugin.swift, FileTreeView.swift, FileTreeNode.swift
  RemoteExplorer/     RemoteFileTreePlugin.swift, RemoteFileTreeView.swift, RemoteFileTreeNode.swift
  Git/                GitPlugin.swift, GitDetailView.swift, GitService.swift
  AIAgent/            AIAgentPlugin.swift, AIAgentDetailView.swift
  Docker/             DockerPlugin.swift, DockerService.swift
  Bookmarks/          BookmarksPlugin.swift, BookmarksPanelView.swift, BookmarkService.swift
  SystemInfo/         SystemInfoPlugin.swift
  Debug/              DebugPlugin.swift
```

Tests mirror this layout under `Tests/ExtermTests/Plugins/`.

The core plugin **framework** (`Plugin/`) is separate from plugin **implementations** (`Plugins/`):

```
Exterm/Plugin/        ExtermPluginProtocol, PluginRegistry, PluginRuntime, PluginHostActions,
                      PluginManifest, PluginWatcher, EnrichmentContext, TerminalContext,
                      WhenClause, ScriptPluginAdapter, JSCRuntime,
                      PluginStateBag, DensityMetrics, ViewDSL/
```

#### Core Protocol: `ExtermPluginProtocol`

All plugins conform to `ExtermPluginProtocol` (which extends `ExtermPlugin: AnyObject`). Key members:

```swift
@MainActor
protocol ExtermPluginProtocol: ExtermPlugin {
    var manifest: PluginManifest { get }
    var whenClause: WhenClauseNode? { get }                    // nil = always visible

    // UI
    func makeDetailView(context: TerminalContext, actionHandler: DSLActionHandler) -> AnyView?
    func makeStatusBarContent(context: TerminalContext) -> StatusBarContent?
    func sectionTitle(context: TerminalContext) -> String?
    var prefersOuterScrollView: Bool { get }                   // false if plugin has its own scroll

    // Host integration (set by PluginRegistry, not by the plugin)
    var hostActions: PluginHostActions? { get set }
    var onRequestCycleRerun: (() -> Void)? { get set }

    // Lifecycle callbacks
    func cwdChanged(newPath: String, context: TerminalContext)
    func remoteSessionChanged(session: RemoteSessionType?, context: TerminalContext)
    func processChanged(name: String, context: TerminalContext)
    func terminalCreated(terminalID: UUID)
    func terminalClosed(terminalID: UUID)
    func terminalFocusChanged(terminalID: UUID, context: TerminalContext)

    // Two-phase cycle (from ExtermPlugin)
    func enrich(context: EnrichmentContext)     // Phase 1: write to shared mutable context
    func react(context: TerminalContext)         // Phase 2: read frozen context
}
```

All methods have default no-op implementations. Only override what your plugin needs.

#### Event Subscriptions

Plugins declare which lifecycle events they care about via `subscribedEvents`. The registry only
delivers callbacks for subscribed events — unsubscribed plugins are skipped entirely. This is
inspired by tmux's control mode subscription system (`refresh-client -B`).

```swift
// Only receive CWD and focus events — skip process, remote, terminal lifecycle
var subscribedEvents: Set<PluginEvent> { [.cwdChanged, .focusChanged] }
```

Available events: `.cwdChanged`, `.processChanged`, `.remoteSessionChanged`, `.focusChanged`,
`.terminalCreated`, `.terminalClosed`, `.remoteDirectoryListed`.

Default: all events (backward compatible). Override to narrow scope.

| Plugin | Subscriptions | Skipped |
|--------|-------------|---------|
| AIAgent | process, cwd, focus | remote, terminal lifecycle, listing |
| Git | cwd, focus | process, remote, terminal lifecycle, listing |
| FileTree | cwd, remote, focus, process | terminal lifecycle, listing |
| RemoteExplorer | process, listing | cwd, focus, remote, terminal lifecycle |
| SystemInfo | cwd, focus | process, remote, terminal lifecycle, listing |
| Bookmarks | *(none)* | all |
| Docker | *(none)* | all |
| Debug | all | *(none)* |

#### PluginHostActions

`PluginHostActions` is a struct of closures that plugins use to request host actions (terminal paste, open tab/pane, etc.). Injected by `PluginRegistry` — plugins never set these themselves:

```swift
struct PluginHostActions {
    var pastePathToActivePane: ((String) -> Void)?
    var openDirectoryInNewTab: ((String) -> Void)?
    var openDirectoryInNewPane: ((String) -> Void)?
    var sendRawToActivePane: ((String) -> Void)?
    weak var bridge: TerminalBridge?
}
```

Use from a plugin: `hostActions?.pastePathToActivePane?(path)`.

#### Plugin Lifecycle & Registration

1. `PluginRegistry.registerBuiltins()` — creates and registers the eight built-in plugins (LocalFileTree, RemoteFileTree, Git, AIAgent, Docker, Bookmarks, SystemInfo, Debug)
2. For each registered plugin, the registry wires:
   - `hostActions` — distributed from `PluginRegistry.hostActions` (set once by MWC)
   - `onRequestCycleRerun` — fires `PluginRegistry.onRequestCycleRerun` (bound to MWC's `runPluginCycle`)
3. `PluginRegistry.registerStatusBarIcons(in:)` — auto-registers toggle icons in the status bar for sidebar-capable plugins (skips file-tree which has a dedicated `FileTreeIconSegment`)

When a plugin needs the host to refresh the sidebar (e.g., Docker containers changed, git status updated), it calls `onRequestCycleRerun?()`. This is preferred over exposing custom callbacks.

#### Two-Phase Plugin Cycle

Every terminal state change triggers a plugin cycle (`PluginRuntime.runCycle`):

1. **Enrich** — `EnrichmentContext` (mutable) is passed to each plugin's `enrich()`. Plugins can write data (e.g., GitPlugin promotes `gitIsDirty`, `gitChangedFileCount`).
2. **Freeze** — `EnrichmentContext.freeze()` produces an immutable `TerminalContext`.
3. **React** — Each plugin's `react()` receives the frozen context.
4. **Evaluate** — `PluginRegistry.runCycle()` evaluates when-clauses, collects visible plugins and status bar content.
5. **Rebuild** — MainWindowController rebuilds the sidebar and status bar from the cycle result.

Budget: < 2ms per plugin per phase. Cycles exceeding 16ms total are logged as warnings.

#### When-Clauses

Plugins declare visibility conditions via `when` in the manifest:

- `"git.active"` — visible only when terminal is in a git repo
- `"!remote"` — visible only in local sessions
- `"remote.type == 'ssh'"` — visible only in SSH sessions
- `"env.local"` — visible only in local sessions (no remote)
- `"env.ssh"` — visible only in SSH/MOSH sessions
- `"env.docker"` — visible only in Docker sessions
- `"process.ai"` — visible only when an AI coding agent is running
- `nil` — always visible

Parsed by `WhenClauseParser` into `WhenClauseNode` AST. Evaluated by `WhenClauseEvaluator` against a `TerminalContext`. Supports `&&`, `||`, `!`, `==`, `!=`, grouping with `()`.

#### TerminalContext

Immutable value type snapshot of terminal state, passed to all plugin UI and lifecycle methods:

- `terminalID`, `cwd`, `remoteSession`, `remoteCwd`
- `gitContext` (branch, repoRoot, isDirty, changedFileCount, stagedCount, stashCount, ahead/behind, lastCommit)
- `processName`, `paneCount`, `tabCount`
- Computed: `isRemote`, `environmentLabel`

#### DSL Action System

Interactive elements in plugin views dispatch `DSLAction` values to `DSLActionHandler`:

| Action Type | Parameters | Effect |
|-------------|-----------|--------|
| `"cd"` | `path` | Sends `cd <path>` to terminal |
| `"open"` | `path` | Opens file in `$EDITOR` (or `open`) |
| `"exec"` | `command` | Sends raw command to terminal |
| `"copy"` | `text` or `path` | Copies to clipboard |
| `"reveal"` | `path` | Opens in Finder |

Built-in plugins can also use `hostActions` closures directly for host-level operations (open tab, open pane, etc.).

#### Context Menus

List items and buttons support a `contextMenu` array for right-click menus. Each item has `label`, `icon` (SF Symbol), `action` (same DSL action types above), and optional `style` (`"destructive"` for red text):

```javascript
{
  label: "file.txt", icon: "doc",
  action: { type: "open", path: "file.txt" },
  contextMenu: [
    { label: "Copy Path", icon: "doc.on.doc", action: { type: "copy", path: "file.txt" } },
    { label: "Delete", icon: "trash", style: "destructive", action: { type: "exec", command: "rm file.txt" } }
  ]
}
```

Parsed by `DSLParser.parseContextMenu()`, rendered via `DSLContextMenuModifier` in `DSLRenderer`.

#### PluginManifest

Both built-in and external plugins have a `PluginManifest`:

```swift
struct PluginManifest {
    let id: String               // Unique plugin ID (e.g. "file-tree", "git-panel")
    let name: String             // Display name
    let version: String
    let icon: String             // SF Symbol name
    let description: String?
    let when: String?            // When-clause expression
    let runtime: PluginRuntime?  // .js for external plugins (nil for built-in)
    var isExternal: Bool         // true for plugins loaded from ~/.exterm/plugins/
    let capabilities: Capabilities?  // sidebarPanel, statusBarSegment
    let statusBar: StatusBarManifest?  // position, priority, template
    let settings: [SettingManifest]?
}
```

Built-in plugins construct manifests inline. External plugins provide `plugin.json`.

`SettingManifest` declares per-plugin settings (key, type, label, default, options). The `options` field is a UI hint: `"fontPicker:system"` renders a system font picker, `"fontPicker:mono"` renders a monospace font picker. Settings are stored in `AppSettings.pluginSettings[pluginID][key]` and rendered dynamically in the Settings → Plugins tab.

#### Plugin Enable/Disable

`disabledPluginIDs` in `AppSettings` is enforced at three levels:
1. `ExtermPluginProtocol.isVisible(for:)` — returns `false` for disabled plugins (before when-clause evaluation)
2. `PluginRegistry.activePlugins` — lifecycle callbacks skip disabled plugins
3. `PluginRegistry.registerStatusBarIcons(in:)` — skips disabled plugins

#### External Plugins

External plugins live in `~/.exterm/plugins/<name>/` and are hot-loaded by `PluginWatcher`:

```
~/.exterm/plugins/my-plugin/
  plugin.json       — Manifest (required)
  main.js           — Plugin logic
```

Plugins run in JavaScriptCore via `JSCRuntime` — no process spawn. The `render(ctx)` function receives the terminal context as an object and returns DSL elements. Host functions `readFile(path)` and `fileExists(path)` provide filesystem access scoped to `ctx.cwd`. Plugin settings declared in the manifest are available via `ctx.settings`.

Output DSL is parsed by `DSLParser` and rendered by `DSLRenderer`. `PluginWatcher` uses FSEvents for hot-loading.

#### Status Bar Plugins (`StatusBarPlugin` protocol)

Status bar segments are a separate, simpler system for the bottom bar. To add a standalone segment:

1. Create a class conforming to `StatusBarPlugin` in `Services/StatusBarPlugin.swift`
2. Set `position` (`.left` or `.right`) and `priority` (lower = closer to edge)
3. Implement `isVisible`, `draw`, `handleClick`, `update`
4. Register in `StatusBarView.registerDefaultPlugins()`

Sidebar plugins get auto-registered toggle icons via `PluginRegistry.registerStatusBarIcons(in:)` — no manual status bar registration needed.

Existing built-in segments: `EnvironmentSegment`, `GitBranchSegment`, `PathSegment`, `ProcessSegment`, `FileTreeIconSegment`, `PaneInfoSegment`, `TimeSegment`. Auto-registered: `PluginIconSegment` instances for Git, AI Agent, Docker, Bookmarks.

#### Adding a New Built-in Plugin

1. Create `Exterm/Plugins/YourPlugin/YourPlugin.swift`
2. Add any views and services in the same directory
3. Conform to `ExtermPluginProtocol` — implement `pluginID`, `manifest`, and the UI/lifecycle methods you need
4. Use `hostActions` for terminal interaction, `onRequestCycleRerun` for triggering sidebar/status bar refresh
5. Register in `PluginRegistry.registerBuiltins()`
6. Add tests in `Tests/ExtermTests/Plugins/YourPlugin/`
7. No `Package.swift` changes needed — SPM resolves recursively

### Auto-Updater

`AutoUpdater` (`Services/AutoUpdater.swift`) checks GitHub Releases for new versions:

- **Check**: `GET https://api.github.com/repos/ph1p/exterm/releases/latest`, compares `tagName` (semver) against `CFBundleShortVersionString`
- **Download**: Downloads DMG to `~/Library/Caches/com.exterm.app/Updates/` with progress
- **Install**: Mounts DMG via `hdiutil`, copies `.app` to staging, verifies code signature via `codesign --verify --deep --strict`, launches a replacement shell script that waits for the old process to exit, replaces the app bundle, and relaunches
- **UI**: `UpdateWindow.swift` — floating NSPanel with release notes, download progress, "Skip/Remind/Install" buttons
- **Settings**: `autoCheckUpdates` (default true), `lastUpdateCheck`, `skipVersion` in `AppSettings`
- **Trigger**: Automatic check on launch (24h interval), manual via "Check for Updates..." menu item

Releases are automated via semantic-release (`.releaserc.json`) — conventional commits on `main` trigger version bumps, DMG builds, and GitHub Releases.

### Workspace Focus Memory

`Workspace` tracks a `focusHistory` (MRU stack of pane IDs, max 32). Updated via `didSet` on `activePaneID`. When a pane is closed, `closePane` restores focus to the most recently focused surviving pane (from history), falling back to the sibling or first leaf. On workspace switch, `activateWorkspace` saves the current focused pane before switching and restores it when returning.

### Process Icons & Matching
- `ProcessIcon.icon(for:)` maps ~100 process names to SF Symbols (vim → `pencil.line`, node → `circle.hexagongrid`, lazygit → `arrow.triangle.branch`, etc.)
- `ProcessIcon.displayName(for:)` maps to human-readable names (nvim → "Neovim", node → "Node.js")
- `ProcessIcon.category(for:)` maps to categories: `editor`, `vcs`, `runtime`, `build`, `package`, `container`, `database`, `monitor`, `filemanager`, `multiplexer`
- `ProcessIcon.isShell()` identifies shell processes that should be transparent in tabs
- Tab bar shows process icon + display name when a non-shell process is running
- When-clause variables: `process.name`, `process.category`, `process.running`, `process.editor`, `process.vcs`
- `foregroundProcess` is persisted in `TabState` per tab (synced from `BridgeState` on process change)
- **Path titles** (starting with `/`, `~/`, `…/`, `./`, `../`) are rejected by `extractProcessName` — they return empty

### IPC Socket Server (`ExtermSocketServer`)

Exterm exposes a Unix domain socket for reliable bidirectional IPC with child processes. This is the authoritative mechanism for process detection — title-based heuristics are the fallback.

#### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Exterm App                                                      │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                  │
│  │ ExtermSocketServer│────▶│  TerminalBridge  │                  │
│  │ ~/.exterm/        │     │                  │                  │
│  │   exterm.sock     │     │ handleTitleChange│                  │
│  │                   │     │  1. Check socket │                  │
│  │ • set_status      │     │  2. If registered│──▶ use socket    │
│  │ • clear_status    │     │  3. If not       │──▶ use title     │
│  │ • list_status     │     └────────┬─────────┘                  │
│  │ • <plugin>.action │              │                            │
│  │                   │     ┌────────▼─────────┐                  │
│  │ Sweep: kill(pid,0)│     │  PluginRegistry  │                  │
│  │ every 5s          │     │  (enrich → react)│                  │
│  └────────┬──────────┘     └──────────────────┘                  │
│           │ onStatusChanged                                      │
│           ▼                                                      │
│  reevaluateSocketProcess()                                       │
│  → updates foregroundProcess                                     │
│  → emits processChanged event                                   │
│  → triggers plugin cycle                                        │
└─────────────────────────────────────────────────────────────────┘
            ▲                          ▲
            │ Unix socket              │ Terminal title (OSC 2)
            │ (EXTERM_SOCK)            │ (Ghostty callback)
┌───────────┴──────────┐   ┌──────────┴──────────┐
│ AI Agent / Tool      │   │ Shell (zsh/bash)     │
│ (Claude, Codex, etc.)│   │ Sets title on cd,    │
│                      │   │ prompt, process start │
│ Registers via:       │   └─────────────────────┘
│ echo '{"cmd":        │
│   "set_status",      │
│   "pid":$$,          │
│   "name":"claude",   │
│   "category":"ai"}'  │
│ | nc -U $EXTERM_SOCK │
└──────────────────────┘
```

#### Two-Tier Process Detection

| Priority | Source | Reliability | How it works |
|----------|--------|-------------|-------------|
| **1 (primary)** | Socket registration | Bulletproof | Process registers its PID + name. Dead PID sweep via `kill(pid, 0)` every 5s. Survives all title changes. |
| **2 (fallback)** | Terminal title | Best-effort | `extractProcessName(from: title)` parses the first word. No sticky logic — process follows the title directly. |

When a socket-registered process is found as a descendant of the shell PID, it **always wins** over the title. The title fallback only applies when no socket registration exists.

#### Socket Protocol

Socket path: `~/.exterm/exterm.sock` (env var `EXTERM_SOCK` inherited by all child shells).
Protocol: newline-delimited JSON. Each command gets a JSON response.

**Full command reference:**

| Category | Command | Fields | Description |
|----------|---------|--------|-------------|
| Process | `set_status` | `pid`, `name`, `category?`, `metadata?` | Register a process. PID must be alive. |
| | `clear_status` | `pid` | Unregister a process. |
| | `list_status` | — | List all registered processes. |
| Query | `get_context` | — | Terminal context (CWD, git, process, remote session). |
| | `get_theme` | — | Current theme name and dark/light mode. |
| | `get_settings` | — | App settings snapshot. |
| | `list_themes` | — | All available theme names. |
| | `get_workspaces` | — | List workspaces with active state. |
| Control | `set_theme` | `name` | Change the active theme. |
| | `toggle_sidebar` | — | Toggle sidebar visibility. |
| | `switch_workspace` | `index` or `id` | Activate a workspace. |
| | `new_tab` | `cwd?` | Open a new tab (optional directory). |
| | `new_workspace` | `path?` | Open a new workspace. |
| | `send_text` | `text` | Write text to the active terminal. |
| Events | `subscribe` | `events` (array) | Subscribe to push events. |
| | `unsubscribe` | `events` (array) | Remove subscriptions. |
| Status Bar | `statusbar.set` | `id`, `text`, `icon?`, `tint?`, `position?`, `priority?` | Push an external segment. |
| | `statusbar.clear` | `id` | Remove an external segment. |
| | `statusbar.list` | — | List all external segments. |
| Plugin | `<ns>.<action>` | varies | Route to a plugin handler. |

**Event subscriptions:** Clients subscribe by sending `{"cmd":"subscribe","events":["cwd_changed","process_changed"]}` and keeping the connection open. Events are pushed as `{"event":"<name>","data":{...}}\n`. Use `["*"]` for all events.

Available events: `cwd_changed`, `title_changed`, `process_changed`, `remote_session_changed`, `focus_changed`, `workspace_switched`, `theme_changed`, `settings_changed`.

**External status bar segments:** Processes push segments via `statusbar.set` with `id`, `text`, optional `icon` (SF Symbol), `tint` (red/green/yellow/blue/orange/purple/accent/#hex), `position` (left/right), `priority` (lower = closer to edge). Segments are auto-removed when the client disconnects.

**Implementation files:**
- `ExtermSocketServer.swift` — core server, subscriptions, external segments
- `ExtermSocketServer+Commands.swift` — query, control, subscription, status bar command handlers
- `ExtermSocketServer+Events.swift` — event broadcasting to subscribers
- `MainWindowController+IPC.swift` — MainActor-side control command handlers, segment updates
- `ExternalStatusBarSegment.swift` — `StatusBarPlugin` conformance for external segments

**Dead process sweep:**
Every 5 seconds, the server checks all registered PIDs with `kill(pid, 0)`. If `errno == ESRCH` (no such process), the registration is removed and `onStatusChanged` fires, which triggers `bridge.reevaluateSocketProcess()` → clears the stale process name.

**Process tree verification:**
`activeProcess(shellPID:)` walks up from each registered PID using `sysctl(KERN_PROC)` to verify it's a descendant of the given shell. This prevents cross-tab interference — an agent in tab 1 won't affect tab 2. Results are cached per sweep cycle to avoid repeated syscalls.

**Thread safety:**
All socket I/O, process mutations, and ancestor lookups happen on a dedicated serial `DispatchQueue`. Public read accessors (`processes`, `activeProcess`, `hasActiveProcesses`) use `queue.sync` for thread-safe snapshots. `onStatusChanged` and `onExternalSegmentsChanged` are always dispatched to main thread. Control commands dispatch to `DispatchQueue.main` for UI mutations and respond back on the socket queue.

**Security:**
- Socket file permissions: `0o600` (owner-only read/write)
- Peer credential check: `getsockopt(LOCAL_PEERCRED)` verifies connecting process has the same UID
- PID existence check: `kill(pid, 0)` on registration verifies the PID is alive
- Client limit: max 128 concurrent connections
- Buffer limit: 64KB per client, disconnects on overflow
- Non-blocking server socket to prevent accept hangs

#### Lifecycle

1. `AppDelegate.applicationDidFinishLaunching` → `ExtermSocketServer.shared.start()`
2. `GhosttyRuntime.init()` → `setenv("EXTERM_SOCK", socketPath, 1)` (before any shell fork)
3. Child shells inherit `EXTERM_SOCK` → agents can connect
4. `MainWindowController.init()` wires `onStatusChanged`, `onControlCommand`, `onExternalSegmentsChanged`
5. Bridge events → `emitEvent()` broadcasts to subscribed clients
6. `AppDelegate.applicationWillTerminate` → `ExtermSocketServer.shared.stop()` (removes socket file, cleans up clients)

### Common Patterns
- `TerminalColor.cgColor` / `.nsColor` extensions for color conversion
- `AppSettings` uses `enum K` for UserDefaults keys, `bool(_:default:)` helper
- Plugin settings: use `AppSettings.shared.pluginBool/pluginString/pluginDouble` to read, `setPluginSetting` to write. Old explorer/git-branch settings are proxies to plugin settings (migrated on first launch via `migratePluginSettings`).
- `shellEscape()` and `fileIcon(for:)` are shared free functions in `Services/`
- `RemoteExplorer.shellEscPath()` must be used (not `shellEscape()`) for any path sent to a remote terminal — it handles tilde expansion correctly by keeping `~` outside quotes
- `NotificationCenter` with `.settingsChanged` for cross-component settings updates
- SwiftUI settings views must include `@ObservedObject private var observer = SettingsObserver()` with `let _ = observer.revision` in their body to re-render on theme changes
- Font cache in GhosttyView for bold/italic variants (hot path optimization)

## Guidelines
- Keep the zero-warnings build
- All AppKit UI operations must be on the main thread
- Use `TerminalColor` extensions instead of inline `CGFloat(r)/255` conversions
- Settings changes go through `AppSettings.shared` which auto-notifies
- Don't add co-authored-by to commits

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/). semantic-release uses these to determine version bumps.

| Prefix | Version bump | When to use |
|--------|-------------|-------------|
| `feat:` | Minor (0.1.0 → 0.2.0) | New feature or capability |
| `fix:` | Patch (0.1.0 → 0.1.1) | Bug fix |
| `chore:` | None | Cleanup, deps, config (no release) |
| `docs:` | None | Documentation only |
| `refactor:` | None | Code change that neither fixes a bug nor adds a feature |
| `test:` | None | Adding or fixing tests |
| `perf:` | Patch | Performance improvement |

**Breaking changes**: Add `BREAKING CHANGE:` in the commit body or `!` after the type (e.g. `feat!:`) for a major bump.

**Commit message style**:
- Keep the first line under 72 characters
- Use imperative mood ("add feature" not "added feature")
- Be specific about what changed, not verbose
- Group related changes in one commit, split unrelated changes

**Examples**:
```
feat: auto-updater via GitHub Releases
fix: file explorer not refreshing after delete
chore: minor cleanup (unused var, plugin expand)
docs: document auto-updater and focus memory
feat!: replace plugin API with new lifecycle hooks
```
