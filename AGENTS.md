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
  Plugins/            Built-in plugins (FileTree, Git, AIAgent, Docker, Bookmarks, etc.)
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

## Guidelines

- Zero warnings policy
- All AppKit UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
- Settings via `AppSettings.shared` with auto-notification
- Use `RemoteExplorer.shellEscPath()` (not `shellEscape()`) for remote paths

## Commit Conventions

[Conventional Commits](https://www.conventionalcommits.org/) — semantic-release uses these for version bumps.

| Prefix | Version bump | Use |
|--------|-------------|-----|
| `feat:` | Minor | New feature |
| `fix:` | Patch | Bug fix |
| `perf:` | Patch | Performance improvement |
| `chore:` | None | Cleanup, deps, config |
| `docs:` | None | Documentation only |
| `ci:` | None | CI changes |
| `refactor:` | None | Code restructuring |
| `test:` | None | Test changes |

Breaking changes: `feat!:` or `BREAKING CHANGE:` in body → major bump.
