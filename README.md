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
- **Remote explorer** — Auto-detects SSH and Docker exec sessions, shows remote file tree
- **Git integration** — Branch name in status bar, clickable branch switcher with local + remote branches
- **Running process** — Status bar shows the foreground process (zsh, node, vim, etc.)
- **Customizable** — Font, cursor style, status bar segments, explorer settings
- **Workspace colors** — Preset or custom colors per workspace, pinning, renaming
- **Undo** — Cmd+Z reopens closed tabs and panes
- **Mouse selection** — Click, double-click (word), triple-click (line)

## Prerequisites

- **macOS 13+** (Ventura or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Zig 0.15+** — `brew install zig`
- **Metal Toolchain** — `xcodebuild -downloadComponent MetalToolchain` (if not already installed)

## Build

### 1. Clone with submodules

```bash
git clone https://github.com/your-username/exterm.git
cd exterm
```

### 2. Get Ghostty

```bash
mkdir -p Vendor
git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty
```

### 3. Build GhosttyKit

```bash
cd Vendor/ghostty
zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
cd ../..
```

This builds `Vendor/ghostty/macos/GhosttyKit.xcframework/` containing `libghostty-fat.a` (~135MB) and headers.

> **Note:** First build downloads dependencies and compiles Metal shaders. Takes 2-5 minutes. Subsequent builds are cached.

### 4. Build Exterm

```bash
swift build
```

### 5. Run

```bash
make run
# or directly:
.build/debug/Exterm
```

### Release build

```bash
swift build -c release
.build/release/Exterm
```

## Quick Start

```bash
# One-liner after cloning
mkdir -p Vendor && git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty && cd Vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast && cd ../.. && make run
```

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+N** | New workspace (home directory) |
| **Cmd+Shift+O** | Open folder as workspace |
| **Cmd+T** | New tab in active pane |
| **Cmd+W** | Smart close (tab → pane → workspace) |
| **Cmd+Z** | Reopen closed tab/pane |
| **Cmd+Shift+W** | Close pane |
| **Cmd+D** | Split right |
| **Cmd+Shift+D** | Split down |
| **Cmd+]** | Focus next pane |
| **Cmd+[** | Focus previous pane |
| **Cmd+B** | Toggle file explorer |
| **Cmd+K** | Clear screen |
| **Cmd+Shift+K** | Clear scrollback |
| **Cmd++** | Increase font size |
| **Cmd+-** | Decrease font size |
| **Cmd+0** | Reset font size |
| **Cmd+C** | Copy selection |
| **Cmd+V** | Paste |
| **Cmd+A** | Select all |
| **Cmd+,** | Settings |

## Architecture

```
Exterm/
  App/              AppDelegate, MainWindowController (window chrome, menus)
  Ghostty/          GhosttyRuntime (app singleton), GhosttyView (Metal surface)
  Terminal/         VT100Terminal (fallback parser), TerminalSession (PTY + I/O)
  Renderer/         TerminalView (CoreText fallback renderer)
  Models/           Workspace, Pane, SplitTree, AppSettings, Theme
  Views/            ToolbarView, PaneView, StatusBarView, FileTreeView, SettingsWindow
  Services/         FileSystemWatcher, RemoteExplorer, KeyMapping, FileIcon
CGhostty/           C module wrapping ghostty.h
CPTYHelper/         C helper for forkpty()
Vendor/ghostty/     Ghostty source (git clone)
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

A built-in VT100 parser exists as a fallback for environments where GhosttyKit isn't available.

### File Explorer

- **Local**: Uses FSEvents for live file system watching
- **Remote SSH**: Auto-detects SSH sessions, lists files via `ssh <host> ls -1AF`
- **Remote Docker**: Auto-detects `docker exec` sessions, lists files via `docker exec <container> sh -c 'ls -1AF'`

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

142 tests covering VT100 parser, models, themes, key mapping, and more.

## License

MIT
