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
  Plugins/            Built-in plugins (FileTree, Git, ClaudeCode, Docker, Bookmarks, Snippets, etc.)
  Views/              PaneView, StatusBarView, ToolbarView, SettingsWindow
  Services/           TerminalBridge, RemoteExplorer, BooSocketServer, AutoUpdater
BooApp/               Executable entry point (just calls BooMain.run())
CGhostty/             C module wrapping ghostty.h
CIronmark/            C module wrapping ironmark (Rust markdown parser)
Tests/BooTests/       717 tests
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

### Subscribed Events

Plugins declare which lifecycle callbacks they receive. Undeclared events are never dispatched:

```swift
var subscribedEvents: Set<PluginEvent> {
    [.cwdChanged, .processChanged]
}
```

`PluginEvent` cases: `.cwdChanged`, `.processChanged`, `.remoteSessionChanged`, `.focusChanged`, `.terminalCreated`, `.terminalClosed`, `.remoteDirectoryListed`.

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

// Agent session tracking
actions?.setAgentSessionID?("session-123")
let id = actions?.getAgentSessionID?()
```

### Plugin Settings

Declare settings in `PluginManifest.settings`. They appear in the Settings sidebar under a **PLUGINS** section — each plugin with settings gets its own dedicated page.

Supported setting types: `bool` (toggle), `double` (slider), `string` (text field or special picker).

Special `options` values for string settings:
- `"fontPicker:system"` / `"fontPicker:mono"` — font picker dropdown
- `"editorExtensions"` — comma-separated file extensions
- `"gitDiffTool"` — diff tool command with `{file}` placeholder
- `"markdownOpenMode"` — segmented picker bound to global `AppSettings.shared.markdownOpenMode`

### Custom Tab Panels

Plugins can open a SwiftUI view in a new tab:

```swift
actions?.openTab?(.customView(title: "My Panel", icon: "puzzlepiece", view: AnyView(MyPanelView())))
```

The view is ephemeral — it is not persisted across app restarts.

### Sidebar Tabs

Set `capabilities.sidebarTab = true` in the manifest and implement `makeDetailView(context:)` (or `makeSidebarTab(context:)` for multi-section panels) to contribute a sidebar tab.

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
