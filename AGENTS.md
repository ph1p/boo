# Boo

A macOS terminal emulator with integrated file explorer, workspace management, and remote session support.

Full documentation: https://ph1p.github.io/boo/

## Build

- **Swift** (macOS 13+), **AppKit**, **GhosttyKit** (Metal GPU rendering)
- Swift Package Manager (`Package.swift`)
- Prerequisites: macOS 13+, Xcode CLT, Zig 0.15+ (`brew install zig`), Rust (`rustup`)

```bash
make setup          # First time: clone Ghostty + build GhosttyKit + build ironmark + build Boo
make run            # Build and launch
make test           # Run tests
swift build         # Build only (requires GhosttyKit already built)
make lint           # swift-format lint
make format         # swift-format format
make app            # Create .app bundle (after make release)
make dmg            # Create distributable DMG
make dist           # Full release: build + bundle + sign + notarize + DMG
make clean-ghostty  # Rebuild GhosttyKit after updating Vendor/ghostty
```

## Project Structure

```
Boo/                  Library target (all app code)
  App/                AppDelegate, MainWindowController, WindowStateCoordinator
  Ghostty/            GhosttyRuntime, GhosttyView (Metal surface)
  Terminal/           TerminalBackend (PTY lifecycle protocol)
  Models/             Workspace, Pane, SplitTree, AppSettings, Theme
  Plugin/             Core plugin framework (protocol, registry, runtime, DSL)
  Plugins/            Built-in plugins (FileTree, Git, Agents, Docker, Bookmarks, Snippets, etc.)
  Views/              PaneView, StatusBarView, ToolbarView, SettingsWindow
  Services/           TerminalBridge, RemoteExplorer, BooSocketServer, BinaryScanner, AutoUpdater
BooApp/               Executable entry point (just calls BooMain.run())
CGhostty/             C module wrapping ghostty.h
CIronmark/            C module wrapping ironmark (Rust markdown parser)
Tests/BooTests/       1072 tests
documentation/        Vocs documentation site
```

## Key Architecture

- **Boo** is a library target; **BooApp** is the thin executable
- **GhosttyKit** embedded via C API — wakeup/tick loop drains surface mailbox
- **Two-layer state**: `AppSettings` (global singleton) + `TabState` (per-terminal)
- **Plugin system**: `BooPluginProtocol` with two-phase cycle (enrich → freeze → react)
- **IPC**: Unix socket at `~/.boo/boo.sock` for child process communication
- **Remote detection**: Title heuristics + process tree polling, reconciled in `TerminalBridge`

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
| `sessionID` | `session_id` from MCP metadata |
| `transcriptPath` | `transcript_path` from MCP metadata |
| `model` | `model` from MCP metadata |
| `mode` | `mode` / `permission_mode` from MCP metadata |
| `state` | `AgentRunState`: `running`, `idle`, `needs-input`, `unknown` |
| `pid` | `pid` from MCP metadata or process tree |
| `cwd` | CWD at session start |

### `WorkspaceAgentSession`

Wraps `AgentSession` with `paneID`, `tabID`, `tabTitle`, and `isFocused` so the plugin can present all active agent tabs across the workspace in a single "Open Sessions" section.

## Settings Architecture

Settings window (`Boo/Views/SettingsWindow.swift`) uses a left sidebar + content pane layout.

### Tab enum

```swift
enum Tab: Equatable {
    case general, theme, appearance, statusBar, layout, plugins, shortcuts
    case pluginSettings(pluginID: String)  // per-plugin settings page
}
```

Fixed tabs are listed in `Tab.fixed`. The **PLUGINS** sidebar section is generated dynamically from enabled plugins that have settings.

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

### Editor Themes

`EditorThemeLibrary` (in `Boo/Content/EditorContentView.swift`) holds all built-in syntax themes.

- Add a new theme as a `static let` `Entry(id:, name:, isDark:, theme:)` and append it to `all`.
- The live editor overrides `theme.background` and `lineHighlight` with the global app theme so the editor blends with the UI; the Settings preview uses the raw theme background.
- `isDark` drives the `Dark`/`Light` badge in the theme picker.

## Browser Tab

`BrowserContentView` (AppKit, `Boo/Content/`) renders a WKWebView with a themed toolbar:

- Background, URL field, separator, and button tints all use `AppSettings.shared.theme` chrome colors (`chromeBg`, `chromeMuted`, `chromeText`, `sidebarBg`, `chromeBorder`).
- Theme changes are applied live via `.settingsChanged` notification → `applyToolbarTheme()`.
- Navigation buttons (back/forward/reload-stop) update their enabled state and tint after each navigation event.

## Guidelines

- Zero warnings policy
- All AppKit UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
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
