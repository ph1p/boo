# Boo

A macOS terminal emulator with integrated file explorer, workspace management, and remote session support.

Full documentation: https://ph1p.github.io/boo/

## Build

- **Swift** (macOS 15+), **AppKit**, **GhosttyKit** (Metal GPU rendering)
- Swift Package Manager (`Package.swift`, swift-tools 6.2)
- Prerequisites: macOS 15+, Xcode CLT, Zig 0.17.0 (`brew install zig`), Rust (`rustup`), Node + pnpm (CodeMirror editor bundle)

```bash
make setup          # First time: clone Ghostty + build GhosttyKit + build ironmark + build Boo
make build          # editor + swift build + bundle Ghostty resources
make run            # Build and launch (debug .app, Sparkle disabled)
make stop           # Quit the dev build only (never the installed /Applications/Boo.app)
make test           # Run tests (builds editor first)
swift build         # Build only (requires GhosttyKit + Boo/Resources/EditorBundle already built)
make editor         # Build the CodeMirror editor bundle (pnpm + Vite) into Boo/Resources/EditorBundle
make lint           # editor-lint + swift-format lint
make format         # editor-format + swift-format format
make release        # Optimized build
make app            # Create .app bundle (runs make release)
make zip            # Create distributable ZIP (+ dSYM ZIP)
make dmg            # Create distributable DMG
make dist           # Full release: app + sign + notarize + ZIP
make clean-ghostty  # Rebuild GhosttyKit after updating Vendor/ghostty
make ghostty-wasm   # Rebuild ghostty-vt.wasm for the Remote Control web UI
```

**Never kill Boo by name.** The installed `/Applications/Boo.app` is often the terminal hosting
this session, and it shares the process name and bundle path suffix with the dev build. Use
`make stop` / `make run`. Do not use `pkill -x Boo`, `killall Boo`, or
`pkill -f "Boo.app/Contents/MacOS/Boo"`.

`Boo/Resources/EditorBundle` is gitignored and is a `.copy` resource of the Boo target, so a bare
`swift build` on a fresh checkout fails until `make editor` (or any of `make build/test/release`) has run.

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
  Content/            Tab content views: Terminal, Browser, Editor (CodeMirror), ImageViewer,
                      MarkdownPreview, PluginTab; ContentType
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
  Resources/          Images, EditorSource (pnpm/Vite) → EditorBundle (generated),
                      RemoteControl (index.html + ghostty-vt.wasm)
BooApp/               Executable entry point (just calls BooMain.run())
CGhostty/             C module wrapping ghostty.h
CIronmark/            C module wrapping ironmark (Rust markdown parser)
CObjCSafe/            Obj-C shim for exception-safe AppKit calls
Vendor/               ghostty + ironmark submodules; patches/ (local Ghostty patches)
Resources/shell-integration/  boo.{zsh,bash,fish}, boo-claude-hook (agent inbox hook), boo-opencode-plugin.js
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
- `WindowManager.dispatchGated` resolves crew handles (`t3`, `parent`) in `tab_id` / `to` to tab UUIDs
  before the approval gate.
- `BooSocketServer.processCommand` only hands allow-listed control commands to the app; a new command
  must be added to its `case` list, or the socket answers "unknown command" (unit tests that call a
  handler directly won't notice; `BooSocketProtocolTests.testCrewCommandsReachTheApp` checks the crew ones).
- `dispatchCommand` first offers `agent_send` / `agent_messages` / `agent_collected` to `AgentCrew.handleSocketCommand`,
  then agent commands to `AgentInbox.handleSocketCommand` (`agent_event`, `agent_inbox`,
  `agent_respond`, `agent_jump`), then routes by `pane_id` to the window owning that
  pane (even in the background), falling back to the active window.
- Per-window handlers: `MainWindowController+IPC.swift` (`handleIPCCommand`: theme, tabs, workspaces,
  send/read text) and `+IPCLayout.swift` (split/close/focus/resize/swap/zoom panes).
- **MCP**: `Boo --mcp` (`BooMCPServer`) is a stdio JSON-RPC server that forwards tool calls to the
  socket; pane arguments default to the caller's `BOO_PANE_ID`.
- **CLI**: `Boo --cli` (`BooCLI`, launcher `~/.boo/bin/boo`, put on `PATH` by shell integration):
  `boo agents | run [--here] | send | inbox | wait | read | status | diff | merge | discard`. Testable through `BooCLI.run(_:env:cwd:send:)`.
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
- `"gitDiffTool"` — diff tool command with `{file}` placeholder; when empty, a Git panel file click opens
  Boo's diff viewer instead
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

`Boo/Plugins/Agents/` — unified plugin for Claude Code, Codex, OpenCode, GitHub Copilot CLI, pi, Hermes, and generic AI CLI sessions.

### Agent detection

Agents are detected via process tree polling: `TerminalBridge` matches the foreground process name against each adapter's `binary` (`AgentKind.infer`). This provides the process name, PID, and cwd.

### `AgentKind`

```swift
enum AgentKind: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case copilot
    case pi
    case hermes
    case custom          // no adapter — always excluded from binary scans
    var adapter: (any AgentAdapter)? { ... }
}
```

Everything agent-specific lives in an `AgentAdapter` (`Boo/Plugins/Agents/Adapters/`): names, binary, argv and title patterns, start/continue/resume commands, how the prompt is passed (positional, a flag, or `_BOO_FIRST_PROMPT` for agents without one), config files for the sidebar, and `installIntegration()` for its hook or plugin. To add an agent: add a case, write an adapter, add it to `AgentKind.adapters`, place it in `AgentKind.detectionOrder`, and add its command to `_BOO_AGENT_CMDS` in `boo.bash`, `boo.zsh` and `boo.fish`.

`AgentBinaryScanner.detectInstalledAgents()` (in `AgentCenterModels.swift`) returns the subset of non-custom kinds whose CLI binary is found on disk via `BinaryScanner.isInstalled`.

### `AgentsPlugin.checkAvailability()`

Runs `AgentBinaryScanner.detectInstalledAgents()` on a background task and stores the result in the static `AgentsPlugin.installedAgents` (the app's one list; `installedKinds` is the
task-capable subset in picker order), then rebuilds the Agents menu. This controls:

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

### Agents switch and entry points

- **Enable Agents** (Agents settings page, `AppSettings.agentsEnabled`, stored as the "agents" entry of
  `disabledPluginIDs`). Off hides the sidebar tab, the Agents menu, the tab menus' agent items, the palette's
  agent rows, the inbox status segment and the terminal's agent button, and stops the jump hotkey.
  Switching off also clears `AgentInbox` (badges, segment and jump read it), and the inbox ignores
  `agent_event`s while off.
- **Integration install** (`BooPaths.syncAgentIntegration`, `BooPaths+AgentIntegration.swift`, re-run on
  `.plugins` settings changes; the files are written on a background queue). On: installs the MCP launcher, the Claude hook, Codex hooks in `~/.codex/hooks.json` (Codex asks the user to trust
  them once via `/hooks`) plus its top-level `notify` in `~/.codex/config.toml` (skipped when the user already has one) and the OpenCode plugin
  `~/.config/opencode/plugins/boo.js` (only when those folders exist). Off: writes `~/.boo/agents-disabled`;
  installed hooks and the OpenCode plugin see the flag and do nothing.
- **Agents menu** (`MainWindowController+AgentMenu.swift`): New Agent… (⌥⌘N), New <Agent> Tab per installed
  agent, Show Crew (⌥⌘A), Jump to Next Waiting Agent (⇧⌘J). `rebuildAgentsMenu()` refills it when the switch
  flips and after the installed-agents scan; while off it is hidden and empty.
- **Tab menus** (`AgentMenuItems`): the tab bar's + menu lists "New <Agent> Tab" and "New Agent…"; a tab's
  context menu has "Start Agent Here" and "Ask Agent About This Tab".
- **Command palette** (`PaletteSources.agents`): Message / Merge / Discard rows per crew agent, from
  `AgentsPlugin.allCrewRows(light: true)` (no task status, no side effects).
- **Drafts**: a crew composer that closes without sending keeps its text per field in memory
  (`AgentCrewUIState.drafts`); Send, Esc and Cancel drop it.
- **Background start**: agent tabs open behind the current one with the prompt in `_BOO_PROMPT` and come
  forward once the agent runs (`pendingReveals`, fired from `paneView(_:commandStarted:)`, or after 1s); messages to a background agent are typed before its tab is shown.

### Agent workflow features

- **Inbox** (`Services/AgentInbox.swift`) — cross-window agent state keyed by terminal tab ID, fed by
  `Resources/shell-integration/boo-claude-hook` via `agent_event`. Shown in the status bar by `AgentInboxSegment`.
- **Worktree tasks** (`AgentWorktree`, `MainWindowController+AgentTasks.swift`) — one git worktree per
  agent task; merge/discard from the task menu. Lives at `~/.boo/worktrees/<repo>/<task>` (branch `boo/<task>`);
  a same-named repo that finds the folder taken by another repository's tasks uses `<repo>-<hash>`.
  Untracked files the repo's `.worktreeinclude` lists (gitignore syntax, as Claude Code reads it; e.g. `.env`)
  are copied into each new worktree. Agents settings, "Tasks" group (app-wide): "Worktree folder"
  (`worktreeFolder`, replaces `~/.boo/worktrees` as `AgentWorktree.defaultRoot`; `builtInRoot` still counts
  for stopped rows) and "Setup command" (`taskSetup`, run before the agent in the task's terminal as
  `<setup>; <agent>` via `MainWindowController.withTaskSetup`, so a failed install still starts the agent).
- **Review mode** (`AgentReview`, `AgentReviewView`) — diff of the agent's changes with inline comments
  sent back to the agent.
- **Diff viewer** — the same view serves the Git panel: `AgentReview.changes(in:source:context:)` reads
  `.branch` (review), `.unstaged` or `.staged`; `MainWindowController.openDiff(repoRoot:source:path:)`
  opens or reuses a "Changes:" / "Staged:" tab (`AgentReviewModel.existing`, a weak registry). Comments,
  Merge/Discard and the footer show only for `.branch`. Layout (unified / side by side via
  `AgentReview.splitRows`), wrap and context lines are Git plugin settings (`DiffSettings`, "Diff Viewer"
  group); the toolbar flips layout and wrap per tab without saving. Review and diff tabs pass their
  folder as the tab cwd (`PaneView.addPluginViewTab(workingDirectory:)`), so the sidebar stays on that repo.
- **Timeline** (`AgentTimeline`, `AgentTimelineView`) — transcript replay with token usage and an
  estimated cost (`AgentTimeline.estimatedCost`).
- **Handoff** (`AgentHandoff`) — ⌥⌘↩ "Send to Agent" pastes the selection or last command output into
  the nearest agent's prompt.
- **Remote approve** (`AgentInbox+Remote.swift`) — `agent_respond` approves/denies a waiting agent from
  the Remote Control page; a mismatched `updated_at` is rejected as stale.
- **Crew** (`Services/AgentCrew.swift`) — agents working together. Every agent tab gets a handle
  (`t1`, `t2`, …). `new_agent_task` / `boo run` link the new agent to the caller as its parent; when
  the child finishes a turn (with its last answer from the Stop hook's `reply`), asks a question,
  errors or exits, a `<boo from="t3 name" state="done">…</boo>` report goes to the parent.
  `send_message` / `boo send` queue messages in an outbox. Delivery is typed into the receiver's
  prompt only when it is a known agent (claude/codex/opencode) in `done`/`error` state, so it never
  interrupts work, answers a permission prompt, or reaches a plain shell. Other tabs read their
  outbox with `read_messages` / `boo inbox`. The orchestrator gets `agent_message` events instead.
  Two agents may send each other at most `AgentCrew.maxMessages` (8) messages per 10 minutes; more is
  refused as a likely loop. Reports and messages from the user are not capped.
  `new_agent_task` with `worktree: false` starts a helper tab in the caller's crew (same cwd).
  Closing a tab closes its helpers without asking (`AgentCrew.tabClosed` from
  `OrchestratorEvents.tabGone`, `MainWindowController.closeHelperTab`); worktrees and branches stay.
  `boo` comes from `~/.boo/bin`; the shell integrations move it to the front of PATH before every
  prompt, because rc files may rebuild PATH and on a case-insensitive disk the app's own `Boo`
  binary (Ghostty appends `Contents/MacOS` to PATH) answers to `boo` and kills the tab.
  `GhosttyRuntime` clears inherited `BOO_*` tab variables, so a Boo started from a Boo terminal
  still loads the integration.
  Claude finds the CLI on its own: `boo-claude-hook` answers `SessionStart` with `additionalContext`
  describing `boo run/agents/wait/send/read`. That hook is registered without `async` (Claude ignores
  an async hook's output); the other events stay async.
  `boo wait` returns the child's answer and then sends `agent_collected`, which drops the child's
  queued reports (not plain messages) from the caller's outbox, so the parent isn't told twice.
  A report the parent took (typed into its prompt, or collected by `boo wait`) marks the helper's
  inbox item seen, so only the parent is left asking for the user's attention.
  A task an agent starts (`new_agent_task` with a caller) opens in the caller's workspace: every
  helper (tasks and `--here`) opens as a tab in the caller's pane, in the caller's crew group
  (`openHelperTab`, `Pane.joinCrew`), and the caller's tab stays shown. A crew is a `TabGroup` with
  `crewParent`: the parent first, then its helpers; only helpers join it (no drop, menu or move
  puts another tab inside), it can't be renamed or recolored, and `pruneGroups` dissolves it once
  the parent or the last helper leaves. Its chip shows ✦ and the most urgent state of its agents
  (collapsed: "✦ boo · 1 waiting"). A parent already in a plain group keeps it; helpers join that.
  A tmux-owned caller pane gets a split instead. Task commands then resolve the worktree
  from the tab's directory and `closeAndRemoveAgentTask` closes only that tab. Without a caller (UI),
  or when the caller's pane is tmux-owned, the task opens its own workspace.
  `boo agents` marks the caller's own row `(you)`: an agent doesn't know its tab's title.
  Helper names (and task branches) default to `AgentCrew.shortName(prompt)` (first sentence, cut at a word);
  `AgentCrew.displayName` strips the agent's status glyph from tab titles. `AgentCrew.name(for:)` picks
  a tab's name: its link name, else its task workspace's name (`taskName`, so the crew row matches the
  workspace pill rather than the title Claude writes), else the title; a non-agent tab (a shell running
  `boo send`) is "shell", since its title is just its last command.
- **Crew sidebar** (`AgentCrewView`, `AgentsPlugin+Crew.swift`) — app-wide agent list grouped into
  Needs you / Working / Done / Stopped, with handles, parent links, queued counts and actions (show, message,
  review, merge, discard, new task). Rows for tabs in no Boo window (another Boo instance or app sharing
  the socket) show "not in a Boo window" and can't be shown, but stay listed. The section sizes to its
  rows (`prefersOuterScrollView: false`), so every agent shows without scrolling; a row's detail is
  the first line of the answer without backticks. An agent with no name (its tab is in no Boo window)
  reads "claude in <folder>", as in `boo agents`. Buttons go through `AgentsPlugin.perform(CrewAction, on:)`.
  No pop-up dialogs: Message, New task and the Discard confirmation are inline fields driven by the shared
  `AgentCrewUIState` (selection + one open composer). The list takes focus like a source list: click or ↑/↓ select,
  double-click or Return shows the agent, Space messages (or resumes a stopped task), Delete asks to discard, Esc closes.
  New task has an agent picker (installed Claude/Codex/OpenCode; last pick kept in `AgentCrewUIState.taskAgent`,
  UserDefaults `crewTaskAgent`). The section stays with no agents: it then offers "Start <agent>" in the active tab.
  Row actions are always laid out and only faded in on hover, so the row never shifts under the pointer.
  A question (`AskUserQuestion`) shows its text, not "needs your permission": the hook sends a
  `question` event from `PreToolUse` (registered with `BooPaths.claudeHookMatchers`, so no other tool
  pays for it), and `AgentInbox` keeps that text when Claude's permission notice follows.
  `AgentInbox.Item.asksQuestion` tells the two apart: a permission prompt row gets inline Allow / Deny
  (`AgentInbox.respond(_:deniedFrom:)`, guarded by `updated_at` like Remote approve); a question row
  doesn't, since Return would pick its first option.
  Creating or removing a task worktree posts `.agentWorktreesChanged`; the Worktrees section rescans
  (its scan is otherwise throttled), so a discarded task's row goes away at once.
  A task workspace under `~/.boo/worktrees` with no live agent in any tab (after a restart, or once the
  agent quit) lists under Stopped (`AgentsPlugin.stoppedTaskRows`, `AgentCrewRow.isStopped`): no handle
  or Message, but Show, Resume, Review, Merge and Discard. The header counts only the Needs you group.
  Resume (`MainWindowController.resumeAgentTask`) continues the task's last conversation in its tab with
  the agent it started with (`claude --continue`, `codex resume --last`, `opencode --continue`; the kind
  is in `<worktree git dir>/boo-agent`, `AgentWorktree.recordAgentKind`). Review's "Send to Agent"
  (`sendToAgent`) on a task with no live agent sends the notes as that resume's prompt
  (`resumeCommand`) instead of pasting them into the bare shell.
  Task rows carry a third line from `AgentTaskStatus` ("2 commits · 5 files · merges into main", or the
  blocker: conflicts, dirty checkouts, no commits). Git runs off the main thread on `mergeCheck` plus
  `git diff --name-only`; answers are cached per worktree for 20s or until the agent's state changes, and
  a changed answer posts `.agentCrewChanged` so the section reruns.
- **Tab badges** (`PaneView.agentBadgeColor` / `drawAgentBadge`) — horizontal tabs show the agent's state
  while it works or waits for the user (colors from `AgentInboxSegment.color`, as in the status bar and
  vertical tabs): a dot on the icon tile's corner, or in the close slot for tabs without an icon (close
  wins there only on hover). A read answer stays quiet. PaneView redraws on `.agentInboxChanged`.
- **Global agent jump** (`AgentJumpHotKey`) — optional system-wide hotkey (`AppSettings.agentJumpHotkey`,
  empty = off; Settings → Keyboard Shortcuts → Agents) running `AgentInbox.jumpToNextAttention`, beeping
  when nothing waits. Same `GlobalHotKey` (Carbon, no Accessibility permission) as the Quick Terminal.
  In-app the Window menu's Jump to Next Waiting Agent (⇧⌘J) does the same.
- Sidebar section order: `MainWindowController.sectionOrder` keeps the user's saved order and puts a
  section it doesn't know (new, or shown only sometimes) right after the section declared before it,
  or first. The first section auto-expands, so a new first section is visible to existing users.
- `debug_snapshot` (DEBUG builds only, socket): `{"cmd":"debug_snapshot","path":"/x.png","sidebar_tab":"agents"}`
  draws the first window, terminals included, to a PNG without screen-recording permission;
  `"dialog": true` draws the open sheet or modal alert instead; `"settings_plugin": "<id>"` draws Settings open on that plugin. `debug_key {key, chars?}` sends a key press (key code) to the key view; it lands in a terminal if one has focus. `debug_crew_action {action, handle?|name?, text?}` (name picks a Stopped row)
  presses a crew button (`message` / `new_task` open their inline field, or send `text` at once); `debug_close_workspace {id}` closes a workspace unasked; `debug_review_send {id, text}` runs the review tab's Send to Agent; `debug_click {x, y, count?}` sends a real left click (`count: 2` double-clicks) at a snapshot point (hit-testing runs, no Accessibility permission needed); `debug_dialog {button, text?}` fills and presses a button in the open
  dialog. Both run their work as run-loop blocks: a modal started inside a main-queue GCD block
  would starve every later socket command (`WindowManager+Debug.swift`).

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

`ContentType` exposes static extension sets used for routing: `imageExtensions`, `markdownExtensions`, `htmlExtensions`, `pdfExtensions`. Add new extension groups here and wire routing in `ContentType.forFile` and the file tree plugin.

### Editor Theme

The editor tab is CodeMirror 6 (bundled from `Boo/Resources/EditorSource` by `make editor`) hosted in `Boo/Content/EditorContentView.swift`. There is no separate editor theme library: `buildEditorTheme()` passes the app theme to the page (dark or light base, token colors from the ANSI palette, editor colors from background/foreground/cursor/selection), and `src/theme.ts` turns it into a CodeMirror theme and highlight style. It is re-applied on theme change.

Languages load lazily. JSON, JavaScript, CSS and HTML format with js-beautify; strict `.json` files are linted.

### Editor Language Servers

`Boo/Content/EditorLanguageServer.swift` runs a language server when one is on the login shell's PATH; without one the editor works as before. `LanguageServerSpec.candidates(for:)` maps editor language names (from `@codemirror/language-data`) to servers in order of preference: TypeScript, CSS/HTML/JSON, Python, Rust, Go, clangd, sourcekit-lsp, Shell, YAML, Lua, Ruby, PHP, Java, Kotlin, C#, Dart, Haskell, Dockerfile, TOML and Markdown. Add a language there. `LanguageServerHub` keeps one server per binary and project root (nearest marker such as `tsconfig.json`, else the git checkout, else the file's directory) and stops it when its last tab closes. Each page runs `@codemirror/lsp-client` (`src/lsp.ts`), so the Swift relay initializes the server once, renumbers request ids, routes replies and per-document notifications to the owning tab, and answers server requests itself. Logs go to the debug log with an `[LSP]` prefix.

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
- UI controls and metrics: follow `documentation/STYLEGUIDE.md` — themed buttons, fields, pickers, switches and steppers (`ThemedControls.swift`, `ThemedPickers.swift`), spacing/radii/heights in `BooStyle`. No stock segmented/menu pickers, `NSPopUpButton`, `Stepper` or `.switch` toggles in Boo chrome.
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
