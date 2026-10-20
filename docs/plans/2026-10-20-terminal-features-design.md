# Terminal Features (non-AI) — Design

Date: 2026-10-20
Status: designed, not yet implemented. Companion to
`2026-10-20-orchestrator-design.md`.

Ten features, chosen by comparing Boo with Ghostty 1.3, iTerm2 3.6/3.7,
Warp and WezTerm. Boo already has activity notifications (`ActivityNotifier`),
find (Boo's `FindBarView` driving Ghostty search), bookmarks and workspace
colors.

## Shared foundations

Three pieces are reused by several features. Build them first.

### A. Action registry (palette, key tables, recipes)

Menu shortcuts are hardcoded `keyEquivalent`s in
`MainWindowController+Menu.swift`, and `ShortcutsSettingsView` is a static list
that can drift from the menu.

- **`ActionRegistry`** enumerates the live `NSMenu` tree, including plugin
  menu items, into `Action { id, title, path, shortcut, isEnabled, perform }`.
  `id` is the menu path ("Window/Split Right"), so it stays stable across
  launches. `perform` sends the item's action through the responder chain, so
  `validateMenuItem` keeps deciding what is enabled.
- `ShortcutsSettingsView` is generated from the registry, so it can no longer
  drift.
- There is still no user rebinding of menu shortcuts (YAGNI). Key tables
  (feature 7) cover custom bindings.

### B. Floating pane host (quick terminal + orchestrator drawer)

The orchestrator design adds a `Pane` outside every `SplitTree`, registered with
`WindowManager`, plus a surface-reparent path that skips
`notifyTerminalClosed`. The quick terminal needs the same thing. Build it once
as **`DetachedPaneHost`** and use it for both.

### C. Per-tab launch spec

Today `pendingInitialInput` carries only a command string, and env is fixed to
`BOO_TERM`, `BOO_PANE_ID` and `BOO_TAB_ID`. Generalize it to
`LaunchSpec { command?, cwd?, env: [String: String] }`, consumed in
`GhosttyView.createSurface` via `addEnv`. Recipes and the IPC `new_tab` (which
gains `command`/`env`) use it.

## 1. Command palette (⌘⇧P)

- An overlay panel centered at the top of the key window, with a fuzzy
  matcher over:
  - registry actions
  - workspaces (all windows)
  - tabs (all panes)
  - bookmarks
  - themes (live preview on highlight; revert on ⎋)
  - recipes
- Results are grouped, with the shortcut shown on the right. Prefixes narrow the
  search: `>` actions, `@` workspaces, `#` tabs, `:` themes.
- Ranking is fuzzy score plus recency (the last 50 picks are kept in
  `AppSettings`).
- Matching is in-process and synchronous; the set is a few hundred items.
- Tests: matcher scoring and order, prefix filtering, a disabled action shown
  dimmed and not run.

## 2. Command blocks (OSC 133)

Ghostty already parses OSC 133. Boo gets `COMMAND_FINISHED` (exit code and
duration; Boo currently ignores `duration`), plus `cmd_start` with the command
text from Boo's shell integration.

- **Jump between prompts:** ⌘↑ / ⌘↓ → `sendBindingAction("jump_to_prompt:-1/1")`.
  This needs no patch.
- **Per-pane command history model:** `[CommandRecord { command, exitCode,
  duration, startedAt, finishedAt }]`, fed from `onCommandStart`/`onCommandEnd`
  and capped at 500 entries.
- **Gutter marks:** a thin colored tick at each prompt row (red for a non-zero
  exit), drawn as an overlay in `TerminalScrollView` from prompt row positions.
- **Select or copy one command's output:** this needs a **Ghostty vendor
  patch** (`Vendor/patches/ghostty-command-output.patch`, applied with
  `make ghostty-patches` like the existing read-text-styled patch). It adds
  `ghostty_surface_read_command_output(surface, offset)`, which walks the
  screen's semantic-prompt rows to find the output range of the Nth-previous
  command.
  - Context menu: "Copy Output", "Copy Command", "Re-run" (`send_text` with the
    command), "Send Output to Agent" (reuses context handoff).
  - ⌥⌘C copies the last command's output.
- **Folding** long output is dropped. Ghostty owns the grid, and faking folds
  would fight the scrollback. Gutter marks plus jump cover the need.
- **Duration:** use Ghostty's `duration` (in ns) instead of Boo's `Date()` diff.
- Tests: the command-history model; the patch's output-range function (as a
  Zig test inside the patch).

## 3. Quick terminal (global hotkey)

- A global hotkey via Carbon `RegisterEventHotKey`. It needs no Accessibility
  permission. Default ⌥Space, configurable in Settings → Shortcuts.
- A borderless `NSPanel` at the `.floating` level that slides down from the top
  of the screen holding the mouse. Height is a percentage of the screen.
  It shows on every Space (`.canJoinAllSpaces`) and over full-screen apps
  (`.fullScreenAuxiliary`).
- Contents: one `DetachedPaneHost` pane, with tabs and splits allowed, and its
  own cwd (home by default). It is persisted in the session snapshot like the
  orchestrator.
- It hides when it loses focus (setting, default on) or when the hotkey is
  pressed again. Hiding never kills the session.
- Tests: hotkey parsing; restoring session state; the hide-on-resign setting.

## 4. Progress bars (OSC 9;4)

- Handle `GHOSTTY_ACTION_PROGRESS_REPORT` in `GhosttyRuntime.ghosttyAction`.
  Payload `{state, progress -1|0-100}`; states are remove, set, error,
  indeterminate, pause.
- Per tab: a progress value on `TabState`. The tab bar draws a 2px bar under the
  tab title (error = red, pause = muted, indeterminate = animated).
- The workspace bar shows the furthest-along progress in that workspace.
- The dock tile shows a progress bar for the key window's active tab; it is
  cleared on `remove`.
- Stale guard: if no update arrives for 15 minutes, the progress clears. This
  matches Ghostty's own behavior.
- Tests: the state machine for each state, and the stale timeout.

## 5. Workspace recipes

- A recipe is a JSON file in `~/.boo/recipes/<name>.json`, so it can be edited
  by hand and shared:

  ```json
  { "name": "dev", "folder": "~/code/app",
    "layout": { "split": "right", "ratio": 0.6,
      "a": { "tabs": [{ "command": "pnpm dev" }] },
      "b": { "split": "down",
        "a": { "tabs": [{ "command": "docker compose logs -f" }] },
        "b": { "tabs": [{ "cwd": "./api", "env": { "PORT": "4000" } }] } } } }
  ```

- **Run:** open the folder as a new workspace, build the `SplitTree`, and give
  each tab a `LaunchSpec` (foundation C).
- **Save current workspace as recipe…**: serializes the layout and cwds.
  Commands aren't stored per tab, so it saves each tab's last `cmd_start` as an
  optional, commented suggestion and leaves `command` empty unless the user
  fills it in.
- Entry points: the palette, File → Recipes submenu, and an IPC/MCP command
  `run_recipe`.
- Errors: an invalid recipe opens an alert naming the JSON path; a missing
  folder is reported and nothing opens.
- Tests: decode/encode round trip, layout → `SplitTree`, relative cwd
  resolution, invalid input.

## 6. Broadcast input

- Per workspace: Terminal → Broadcast Input to → **All Panes in Workspace** /
  **Selected Panes…**. Selected panes uses ⌘-click on panes to toggle them.
- Key events from the focused `GhosttyView` are mirrored to the other members
  with `ghostty_surface_key`. Paste and IME commit text are mirrored with
  `ghostty_surface_text`.
- Members show an orange border, and the status bar reads "Broadcasting to N
  panes". This is a strong visual cue, because typing into the wrong host is the
  classic broadcast accident.
- Safety:
  - Agent panes are never members.
  - Remote panes are allowed, since that is the main use case (several SSH
    hosts).
  - Broadcast turns off when the workspace switches or the group shrinks to one
    pane.
- Tests: membership rules (agent exclusion, auto-off), and event fan-out with
  fake surfaces.

## 7. Key tables (leader-key mode)

- A leader key (default ⌃A, configurable, off by default) enters a modal table.
  The next key looks up an action in `~/.boo/keytables.json`:
  `{ "leader": "ctrl+a", "tables": { "root": { "v": "Window/Split Right",
  "w": { "table": "window" } }, "window": { … } } }`.
- Values are `ActionRegistry` ids (foundation A), `send:<text>`, or
  `{ "table": … }` for chained tables.
- While the mode is active, an indicator shows in the status bar ("⌃A → window")
  and the next key goes nowhere else. ⎋ or a 2s timeout exits.
- An unknown action id is reported once at load, in an alert that names the key.
- The key interception happens in `GhosttyView.keyDown` before the key is
  forwarded to Ghostty, so Ghostty's own keybinds are unaffected while the mode
  is off.
- Tests: config parsing, table chaining, timeout, unknown-id validation.

## 8. Tab groups, vertical tabs, auto-color

- **Vertical tabs:** a new `TabOverflowMode.vertical` per pane shows a narrow
  column on the pane's left listing its tabs, with the title, the cwd basename,
  and dots for progress and agent state. It's useful for agent-heavy panes with
  many tabs.
- **Tab groups:** a named, colored group within a pane's tab bar. Drag a tab
  onto another to create a group; groups can be collapsed into a single chip.
  `Pane.Tab` gains `groupID?`, and groups are persisted in `SessionPane`.
- **Auto-color workspaces:** a setting that gives each new workspace a stable
  color derived from its git root path hash (or folder path). A manual color
  always wins.
- Tests: group persistence round trip, collapse state, color hash stability.

## 9. Session recording (asciinema)

- There is no pty tap today, so a **Ghostty vendor patch** is needed. It adds an
  optional per-surface output callback
  `ghostty_surface_set_output_callback(surface, cb, userdata)`, invoked from the
  termio read path with the raw bytes.
- `SessionRecorder` writes asciicast v2 (`.cast`: a header plus
  `[t, "o", data]` lines) on a background queue. It also records resize events
  (`"r"`).
- UI: Terminal → Start/Stop Recording, with a red dot on the tab while
  recording. Files are saved to `~/.boo/recordings/<date>-<title>.cast` and
  revealed in Finder.
- Replay: open a `.cast` in a new **cast player tab** content type, which feeds
  the recorded bytes into a read-only surface and has play, pause and speed
  controls.
- Privacy: recording is never automatic; there is a clear indicator; input
  (`"i"`) is not recorded, so typed passwords stay out.
- Tests: the asciicast writer (timestamps, escaping, resize), the player's
  timing schedule.

## 10. Phone push notifications

The remote-control server is plain HTTP on the LAN and its web UI polls. Web
Push and service workers need a secure context, so **browser push over LAN
HTTP is not possible**.

- Instead, an **outgoing webhook in ntfy format**. In Settings → Notifications,
  a "Push to phone" URL (e.g. `https://ntfy.sh/<secret-topic>` or a self-hosted
  ntfy server). Boo POSTs a title and body for:
  - an agent waiting for input
  - a long command finished (threshold setting, default 60s)
  - an SSH session dropped
- **Off by default.** This sends data to an external service, so the settings
  page says exactly what is sent: event type, workspace name and agent name.
  Never terminal content.
- **Deep link:** when remote control is running, the push carries a `Click`
  URL to the remote web UI, so tapping the notification opens the page where
  you can approve the agent.
- **PWA polish:** add a web manifest and icons so the remote page can be added
  to the home screen. That works over HTTP; push does not.
- Delivery: `URLSession`, fire-and-forget, 5s timeout, at most one push per
  event type per 10s. Failures are logged and never retried in a loop.
- Tests: payload building (no terminal content), throttle, the disabled-by-
  default setting.

## Implementation order

1. Foundations A (action registry) and C (launch spec).
2. Command palette.
3. Progress bars, command blocks without the patch (jump, gutter, history),
   then the command-output patch.
4. Foundation B (shared with the orchestrator), then quick terminal.
5. Recipes, broadcast input, key tables.
6. Tab groups, vertical tabs, auto-color.
7. Session recording (vendor patch, writer, player).
8. Phone push and the PWA manifest.
