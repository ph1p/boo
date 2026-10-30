# Boo

A macOS terminal emulator with integrated file explorer, workspace management, and remote session support.

Full documentation: https://ph1p.github.io/boo/

## Build

- **Swift** (macOS 15+), **AppKit**, **GhosttyKit** (Metal GPU rendering)
- Swift Package Manager (`Package.swift`, swift-tools 6.2)
- Prerequisites: macOS 15+, Xcode CLT, Zig 0.17.0 (`brew install zig`), Rust (`rustup`), Node + pnpm (Monaco editor bundle)

```bash
make setup          # First time: clone Ghostty + build GhosttyKit + build ironmark + build Boo
make build          # monaco + swift build + bundle Ghostty resources
make run            # Build and launch (debug .app, Sparkle disabled)
make test           # Run tests (builds monaco first)
swift build         # Build only (requires GhosttyKit + Boo/Resources/MonacoBundle already built)
make monaco         # Build the Monaco editor bundle (pnpm + Vite) into Boo/Resources/MonacoBundle
make lint           # monaco-lint + swift-format lint
make format         # monaco-format + swift-format format
make release        # Optimized build
make app            # Create .app bundle (runs make release)
make zip            # Create distributable ZIP (+ dSYM ZIP)
make dmg            # Create distributable DMG
make dist           # Full release: app + sign + notarize + ZIP
make clean-ghostty  # Rebuild GhosttyKit after updating Vendor/ghostty
make ghostty-wasm   # Rebuild ghostty-vt.wasm for the Remote Control web UI
```

`Boo/Resources/MonacoBundle` is gitignored and is a `.copy` resource of the Boo target, so a bare
`swift build` on a fresh checkout fails until `make monaco` (or any of `make build/test/release`) has run.

Ghostty carries local patches (`Vendor/patches/*.patch`), applied idempotently by
`make ghostty` / `make ghostty-wasm`. After updating the submodule, re-apply via
`make ghostty-patches` and re-sync `CGhostty/include/ghostty.h` from
`Vendor/ghostty/include/ghostty.h`. Ghostty pins its own zig version
(`build.zig.zon minimum_zig_version`) — keep a matching zig on PATH.

## Project Structure

```
Boo/                  Library target (all app code)
  App/                AppDelegate (BooMain), AppStore, WindowManager, MainWindowController (+Panes,
                      +Terminal, +Plugins, +Workspace, +Menu, +IPC, +IPCLayout, +SplitLayout,
                      +WindowDrag, +AgentTasks, +AgentTimeline, +RemoteControl), SidebarController,
                      WindowStateCoordinator, TrafficLightPositioner
  Content/            Tab content views: Terminal, Browser, Editor (Monaco), ImageViewer,
                      MarkdownPreview, PluginTab; ContentType + ContentTypeDetector
  Ghostty/            GhosttyRuntime, GhosttyView (Metal surface), TerminalScrollView
  Models/             Settings.swift (AppSettings), Theme + TerminalTheme+BuiltIn, Workspace,
                      Pane (+ TabState), SplitTree (+Layout), AppState
  Plugin/             Core plugin framework (protocol, registry, runtime, JSC script plugins)
    ViewDSL/          JSON view DSL parser/renderer for script plugins
  Plugins/            Built-in plugins (Agents, FileTree, RemoteExplorer, Git, Docker, Bookmarks,
                      Snippets, SystemInfo, Debug)
  Services/           TerminalBridge, ProcessTree, RemoteExplorer, SessionStore, BooPaths,
                      BinaryScanner, SparkleUpdater
                      Sockets: SocketServerCore, BooSocketServer (+Commands, +Events),
                      RemoteControlServer, BooMCPServer
                      Agents: AgentInbox (+Remote), AgentWorktree, AgentReview, AgentTimeline,
                      AgentHandoff
  Views/              PaneView, SplitContainerView, StatusBarView, ToolbarView, WorkspaceBarView,
                      TabDragCoordinator, ZoomBadgeView, DetailPanelView (SidebarPanelView),
                      AgentReviewView, AgentTimelineView, AgentInboxSegment, SettingsWindow
    Settings/         One SwiftUI view per settings page
    SwiftUI/          AppContentView, SidebarView, PaneSplitRepresentable
  Resources/          Images, MonacoSource (pnpm/Vite) → MonacoBundle (generated),
                      RemoteControl (index.html + ghostty-vt.wasm)
BooApp/               Executable entry point (just calls BooMain.run())
CGhostty/             C module wrapping ghostty.h
CIronmark/            C module wrapping ironmark (Rust markdown parser)
CObjCSafe/            Obj-C shim for exception-safe AppKit calls
Vendor/               ghostty + ironmark submodules; patches/ (local Ghostty patches)
Resources/shell-integration/  boo.{zsh,bash,fish}, boo-claude-hook (agent inbox hook)
examples/plugins/     Example script plugins
Tests/BooTests/       1300+ tests
documentation/        Vocs documentation site
```

## Key Architecture

- **Boo** is a library target; **BooApp** is the thin executable
- **GhosttyKit** embedded via C API — wakeup/tick loop drains surface mailbox; Ghostty owns the PTY
- **State layers**: `AppSettings` (global singleton) + `TabState` (per-terminal, source of truth) +
  `AppStore` (observable projection of context/theme/sidebar for SwiftUI)
- **Plugin system**: `BooPluginProtocol` with two-phase cycle (enrich → freeze → react)
- **IPC**: Unix socket at `~/.boo/boo.sock` — child-process status, layout/window control API,
  transport for the MCP server, and backend for remote control (see [IPC](#ipc))
- **Multi-window**: `WindowManager` owns every `MainWindowController`; each window has its own
  workspaces, sidebar and plugin registry, while settings/themes/bookmarks stay global. Session v2
  (`SessionStore`) snapshots all windows (`SessionSnapshot.windows` + `keyWindowIndex`).
- **Remote detection**: Title heuristics + process tree polling, reconciled in `TerminalBridge`

## IPC

- `BooSocketServer.processCommand` handles built-ins (`set_status`, `clear_status`, `list_status`, …)
  and plugin-namespaced handlers; control commands reach `WindowManager.dispatchCommand` via
  `onControlCommand` (installed in `WindowManager.installSharedHandlers`).
- `dispatchCommand` first offers agent commands to `AgentInbox.handleSocketCommand` (`agent_event`,
  `agent_inbox`, `agent_respond`, `agent_jump`), then routes by `pane_id` to the window owning that
  pane (even in the background), falling back to the active window.
- Per-window handlers: `MainWindowController+IPC.swift` (`handleIPCCommand`: theme, tabs, workspaces,
  send/read text) and `+IPCLayout.swift` (split/close/focus/resize/swap/zoom panes).
- **MCP**: `Boo --mcp` (`BooMCPServer`) is a stdio JSON-RPC server that forwards tool calls to the
  socket; pane arguments default to the caller's `BOO_PANE_ID`.
- `RemoteControlServer` (HTTP, web UI) feeds its `onCommand` into the same `dispatchCommand`.

## Plugin System

Plugins implement `BooPluginProtocol`. The registry runs a cycle (enrich → freeze → react) with a <16ms budget. Each cycle carries a `PluginCycleReason`: `.focusChanged`, `.cwdChanged`, `.titleChanged`, `.processChanged`, `.remoteSessionChanged`, `.workspaceSwitched`.

### Availability Check

Plugins can gate themselves on external prerequisites (binary installed, socket reachable, etc.) via an async one-time check:

```swift
func checkAvailability() async -> Bool {
    await Task.detached(priority: .utility) {
        BinaryScanner.isInstalled("mytool")
    }.value
}
```

The registry calls this after registration and again whenever the plugin's sidebar tab is activated (so a tool installed while Boo is running is picked up on next focus). Until the check completes the plugin is shown optimistically to avoid flicker. Return `false` to hide the plugin from all UI — sidebar tab, status bar, and when-clauses all become inactive.

`BinaryScanner` (`Boo/Services/BinaryScanner.swift`) searches `$PATH` plus common install locations (`/opt/homebrew/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.nvm/current/bin`).

### Subscribed Events

Plugins declare which lifecycle callbacks they receive. Undeclared events are never dispatched:

```swift
var subscribedEvents: Set<PluginEvent> {
    [.cwdChanged, .processChanged]
}
```

`PluginEvent` cases: `.cwdChanged`, `.processChanged`, `.remoteSessionChanged`, `.focusChanged`, `.terminalCreated`, `.terminalClosed`, `.remoteDirectoryListed`, `.commandStarted`, `.commandEnded`.

### Activation Hooks

```swift
func pluginDidActivate()    // sidebar tab selected, or statusbar-only plugin becomes visible
func pluginDidDeactivate()  // tab deselected / plugin hidden — pause background work here
```

Both have empty default implementations.

### Plugin API

```swift
// Open tabs from a plugin
actions?.openTab?(.terminal(workingDirectory: path))
actions?.openTab?(.browser(url: url))
actions?.openTab?(.file(path: path))           // respects markdownOpenMode
actions?.openTab?(.customView(title: "Panel", icon: "star", view: AnyView(MyView())))

// Send to terminal
actions?.exec("ls -la")
actions?.sendToTerminal?("some text")

// Multi-content tab (reusable factory — register once, open many)
actions?.registerMultiContentTab?("type-id") { ctx in AnyView(MyView(ctx: ctx)) }
actions?.openMultiContentTab?("type-id", PluginTabContext(title: "Output", icon: "terminal"))

// Agent session tracking (per-tab, stored in TabState)
actions?.setAgentSessionID?("session-123")
let id = actions?.getAgentSessionID?()

// Query active agent sessions across all terminal tabs in the workspace
let sessions: [WorkspaceAgentSession] = actions?.workspaceAgentSessions?() ?? []
actions?.focusAgentSession?(session.id)
```

### TerminalContext — Process Fields

`TerminalContext` now exposes full foreground process metadata resolved from the socket registry:

| Field | Type | Description |
|---|---|---|
| `process` | `String` | Process name (e.g. `"claude"`) |
| `processPID` | `pid_t?` | PID reported by the socket registration |
| `processCategory` | `String?` | Category tag (e.g. `"ai"`, `"editor"`) |
| `processMetadata` | `[String: String]` | Arbitrary key/value metadata from `set_status` |

These are populated from `BooSocketServer.activeProcess(shellPID:)` when a socket registration exists, and fall back to title-heuristic detection otherwise.

### Plugin Settings

Declare settings in `PluginManifest.settings`. They appear in the Settings sidebar under a **PLUGINS** section — each plugin with settings gets its own dedicated page.

Supported setting types: `bool` (toggle), `double` (slider), `string` (text field or special picker).

Each setting supports an optional `description` field shown as help text below the control.

Special `options` values for string settings:
- `"fontPicker:system"` / `"fontPicker:mono"` — font picker dropdown
- `"editorFilePatterns"` — comma-separated file patterns (e.g. `*.ts, .env*`)
- `"dockerSocket"` — socket path with auto-detect fallback
- `"gitDiffTool"` — diff tool command with `{file}` placeholder
- `"markdownOpenMode"` — picker bound to global markdown open mode setting
- `"imageOpenMode"` — picker bound to global image open mode setting
- `"textOpenMode"` — picker bound to global text open mode setting

### Custom Tab Panels

Plugins can open a SwiftUI view in a new tab:

```swift
actions?.openTab?(.customView(title: "My Panel", icon: "puzzlepiece", view: AnyView(MyPanelView())))
```

The view is ephemeral — it is not persisted across app restarts.

### Sidebar Tabs

Set `capabilities.sidebarTab = true` in the manifest and implement `makeDetailView(context:)` (or `makeSidebarTab(context:)` for multi-section panels) to contribute a sidebar tab.

## Agent Center (Agents Plugin)

`Boo/Plugins/Agents/` — unified plugin for Claude Code, Codex, OpenCode, and generic AI CLI sessions.

### Agent detection

Agents are detected via process tree polling: `TerminalBridge` matches the foreground process name against `AgentKind.processNames`. This provides the process name, PID, and cwd.

### `AgentKind`

```swift
enum AgentKind: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case custom          // no associated binary — always excluded from binary scans
}
```

`AgentBinaryScanner.detectInstalledAgents()` (in `AgentCenterModels.swift`) returns the subset of non-custom kinds whose CLI binary is found on disk via `BinaryScanner.isInstalled`.

### `AgentsPlugin.checkAvailability()`

Runs `AgentBinaryScanner.detectInstalledAgents()` on a background task and stores the result in `installedAgents`. This controls:

- **Empty state** — shows provider-specific "Start X" buttons only for installed CLIs; shows a plain "No agent CLIs installed" message when none are found
- **Settings view** — `AgentCenterSettingsView(installedAgents:)` filters the Providers section to show only installed agents

### `AgentSession` fields

| Field | Source |
|---|---|
| `kind` | Inferred from process name or `agent_kind` metadata |
| `displayName` | Human-readable agent name |
| `processName` | Foreground process name |
| `startedAt` | When the session was first seen |
| `sessionID` | `session_id` from MCP metadata |
| `transcriptPath` | `transcript_path` from MCP metadata |
| `model` | `model` from MCP metadata |
| `mode` | `mode` / `permission_mode` from MCP metadata |
| `state` | `AgentRunState`: `running`, `idle`, `needs-input`, `unknown` |
| `pid` | `pid` from MCP metadata or process tree |
| `cwd` | CWD at session start |
| `metadata` | Raw `set_status` metadata |

### `WorkspaceAgentSession`

Wraps `AgentSession` with `paneID`, `tabID`, `tabTitle`, and `isFocused` so the plugin can present all active agent tabs across the workspace in a single "Open Sessions" section.

### Agent workflow features

- **Inbox** (`Services/AgentInbox.swift`) — cross-window agent state keyed by terminal tab ID, fed by
  `Resources/shell-integration/boo-claude-hook` via `agent_event`. Shown in the status bar by `AgentInboxSegment`.
- **Worktree tasks** (`AgentWorktree`, `MainWindowController+AgentTasks.swift`) — one git worktree per
  agent task; merge/discard from the task menu.
- **Review mode** (`AgentReview`, `AgentReviewView`) — diff of the agent's changes with inline comments
  sent back to the agent.
- **Timeline** (`AgentTimeline`, `AgentTimelineView`) — transcript replay with token usage and an
  estimated cost (`AgentTimeline.estimatedCost`).
- **Handoff** (`AgentHandoff`) — ⌥⌘↩ "Send to Agent" pastes the selection or last command output into
  the nearest agent's prompt.
- **Remote approve** (`AgentInbox+Remote.swift`) — `agent_respond` approves/denies a waiting agent from
  the Remote Control page; a mismatched `updated_at` is rejected as stale.

## Settings Architecture

Settings window (`Boo/Views/SettingsWindow.swift`) uses a left sidebar + content pane layout.

### Tab enum

```swift
enum Tab: Hashable {
    case general, theme, appearance, statusBar, layout, profiles, rules, recordings, permissions
    case editor, browser, notifications, plugins, shortcuts
    case pluginSettings(pluginID: String)  // per-plugin settings page
    // `group` places each tab in a sidebar section; `keywords` feed the sidebar search.
}
```

Fixed tabs are listed in `Tab.fixed`, ordered by `Tab.Group` (Terminal, Appearance, Apps, Plugins). The **Plugins** section also lists, dynamically, the enabled plugins that have settings. New tabs need a `group` and `keywords` entry.

### Adding a setting to a built-in plugin

1. Add a `PluginManifest.SettingManifest` entry to the plugin's `manifest.settings` array.
2. Read it via `context.settings.bool("key", default: false)` (or `.string` / `.double`).
3. The setting will automatically appear on the plugin's dedicated settings page.

### Content Types

`ContentType` enum: `terminal`, `browser`, `editor`, `imageViewer`, `markdownPreview`, `pluginView`.

- `pluginView` — hosts a plugin-provided `AnyView` via `PluginTabContentView`. State is ephemeral.
- Only `terminal` tabs support the plugin sidebar (`supportsPlugins = true`).
- PDF files resolve to `.browser` — WKWebView renders them natively without a plugin.

`ContentType` exposes static extension sets used for routing: `imageExtensions`, `markdownExtensions`, `htmlExtensions`, `pdfExtensions`. Add new extension groups here and wire routing in `ContentType.forFile`, `ContentTypeDetector.detect`, and the file tree plugin.

### Editor Theme

The editor tab is Monaco (bundled from `Boo/Resources/MonacoSource` by `make monaco`) hosted in `Boo/Content/EditorContentView.swift`. There is no separate editor theme library: `buildMonacoTheme()` derives a Monaco theme from the app theme (`vs`/`vs-dark` base, token colors from the ANSI palette, editor colors from background/foreground/cursor/selection) and re-applies it on theme change.

## Browser Tab

`BrowserContentView` (AppKit, `Boo/Content/`) renders a WKWebView with a themed toolbar:

- Toolbar background uses `theme.background`; URL field, separator, and button tints use chrome colors (`chromeText`, `chromeMuted`, `chromeBorder`), with `controlFill` as button hover background.
- Theme changes are applied live via `.settingsChanged` notification → `applyToolbarTheme()`.
- Navigation buttons (back/forward/reload-stop) update their enabled state and tint after each navigation event.

## Guidelines

- Zero warnings policy
- All AppKit UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
- Colors: use the semantic tokens on `TerminalTheme` instead of `chromeMuted.withAlphaComponent(…)` or hardcoded `NSColor`s — token table in `documentation/docs/pages/theming.mdx`. SwiftUI mirrors live on `Tokens` (`SettingsWindow.swift`).
- Settings via `AppSettings.shared` with auto-notification
- Use `RemoteExplorer.shellEscPath()` (not `shellEscape()`) for remote paths

## Commit Conventions

[Conventional Commits](https://www.conventionalcommits.org/) — semantic-release uses these for version bumps.

| Prefix      | Version bump | Use                     |
| ----------- | ------------ | ----------------------- |
| `feat:`     | Minor        | New feature             |
| `fix:`      | Patch        | Bug fix                 |
| `perf:`     | Patch        | Performance improvement |
| `chore:`    | None         | Cleanup, deps, config   |
| `docs:`     | None         | Documentation only      |
| `ci:`       | None         | CI changes              |
| `refactor:` | None         | Code restructuring      |
| `test:`     | None         | Test changes            |

Breaking changes: `feat!:` or `BREAKING CHANGE:` in body → major bump.
