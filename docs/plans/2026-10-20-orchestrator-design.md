# Orchestrator Drawer — Design

Date: 2026-10-20
Status: implemented on `feat/orchestrator`

## Goal

One AI orchestrator per app that sees every window, workspace, pane and agent,
and can **triage** (explain and unblock waiting agents), **dispatch** (split work
into parallel worktree tasks) and **integrate** (review, conflict-check and merge
finished tasks). It is a Claude Code session in a slide-over drawer, driving Boo
through the existing MCP server.

## Decisions

| Topic | Decision |
|---|---|
| Brain | Claude Code session, Boo MCP preconfigured, bundled system prompt |
| Scope | Whole app: all windows, workspaces, agents |
| Autonomy | Reads free; writes to non-owned panes gated by a Boo-side approval card |
| Job | Triage + dispatch + integrate, all in the first implementation |
| UI | Right-edge slide-over drawer, global toggle ⌥⌘O (⌘⇧O is Open Folder) |
| Events | Blocking `wait_for_events` MCP tool (no prompt injection) |
| Conflicts | Owning task agent rebases in its own worktree; main checkout never left mid-conflict |
| Persistence | Resume the same conversation via `claude --resume <session_id>` |

## 1. Architecture

### OrchestratorController (app singleton, next to `AgentInbox`)

- Owns an **`OrchestratorPane`**: a real `Pane` that is not in any `SplitTree`,
  holding one terminal tab. It is registered with `WindowManager` as an
  app-level owner, so `dispatchCommand` can route its `pane_id` instead of
  falling back to `activeController`.
- Holds the Claude `session_id`, the **owned-tabs set** (tab IDs of agents it
  spawned) and the per-pane capability tokens.
- State persists in the session-restore snapshot (`~/.boo/session.json`, new
  optional `orchestrator` field on `SessionSnapshot`), not in `AppSettings`:
  this is runtime state, not a preference.

### OrchestratorDrawerView

Right-edge slide-over overlaid above the window content, including the right
sidebar (which defaults to the right edge). Resizable width, kept in
`AppSettings` (a preference). Top to bottom:

1. **Agent strip**: compact rows from `AgentInbox` (state dot, name,
   workspace, owned badge); click jumps to the agent.
2. **Approval cards** (section 3).
3. **Terminal**: the orchestrator's `GhosttyView`.

Rules:

- Attached to one window at a time. It moves **only when you open it in
  another window**, not on key-window changes. Moving reparents the
  `GhosttyView` directly through a new `reparentSurface` path that does **not**
  call `notifyTerminalClosed` (tear-off does, which would spam plugins and
  process detection).
- No window open: park the surface in a hidden borderless holder window so the
  pty survives; reattach when a window opens.
- The orchestrator tab is invisible to per-window plugins (`ClaudeCodePlugin`,
  status bar, process tracker).

### Launch

```
claude [--resume <id>] --mcp-config <~/.boo/orchestrator/mcp.json> \
       --append-system-prompt "$(cat <bundled orchestrator prompt>)"
```

Env: `BOO_PANE_ID`, `BOO_TAB_ID`, `BOO_TOKEN` (gated class), and
`MCP_TOOL_TIMEOUT=600000`. Boo writes `mcp.json` itself, so the user doesn't
have to run `claude mcp add`. The system prompt is bundled under
`Resources/orchestrator/` and describes the triage / dispatch / integrate loop
and its rules: never merge without `task_diff` + a summary; on conflict, ask
the owning agent to rebase; never stash or touch the user's main checkout.

### Inbox self-exclusion

The orchestrator's own Claude hooks emit `agent_event`s like any agent. Boo
tags these itself: `resolveTabID` returning the orchestrator tab means role
`orchestrator`. No hook script change is needed. The inbox keeps that item
apart from the others: it is excluded from `list_agents`, the agent strip and
⌘⇧J, and its state drives the drawer toggle's icon.

## 2. MCP tool surface

### Changed tools

| Tool | Change |
|---|---|
| `get_layout` | `scope: "app"` → windows → workspaces → panes → tabs, each with agent state and an `owned` flag |
| `read_pane` | Accepts `tab_id` as well as `pane_id`; works across windows |
| `new_agent_task` | Returns `tab_id` (today it replies with `activeWorkspace`, which is wrong when called from the drawer); explicit `repo`; adds `base`, `model`, `agent`; registers ownership **before** replying |
| `split_pane`, `open_review` | An explicit target is required when the caller is the orchestrator |

### New tools

| Tool | Wraps | Gated |
|---|---|---|
| `wait_for_events(timeout, since)` | Inbox change events, held reply | no |
| `agent_respond(tab_id, approve\|deny\|text)` | Existing `agent_respond` | yes, unless owned |
| `focus_pane(tab_id)` | Existing `agent_jump` | no |
| `task_status(tab_id)` | `AgentWorktree.status` + `git merge-tree --write-tree` conflict check + `target_dirty` | no |
| `task_diff(tab_id, stat_only)` | `AgentReview.changes` | no |
| `merge_task(tab_id, cleanup)` | `AgentWorktree.merge` | **always**, even when owned |
| `discard_task(tab_id)` | `AgentWorktree.remove` | **always** |

### wait_for_events

- Boo keeps an in-memory ring of events with a monotonic `seq`, fed from
  `.agentInboxChanged`, task spawn/finish, pane close and approval resolution.
- The call returns at once if any event has `seq > since`; otherwise Boo holds
  the reply (the socket server already replies through an async closure and has
  no idle timeout) until an event arrives or `timeout` expires, and then returns
  `[]`.
- `BooSocketClient.request` gets a per-call timeout (today it is a fixed 10s
  `SO_RCVTIMEO`).
- Event types: `state_changed`, `task_spawned`, `task_finished`, `pane_closed`,
  `approval_resolved`.
- Add a matching `agent_state_changed` socket subscription event (none exists
  today) for external clients.

### Merge safety fix

`AgentWorktree.merge` checks only whether the **worktree** is dirty. Add a
dirty check on `mainRoot` (`git status --porcelain`) for both the existing menu
merge and `merge_task`. When the main checkout is dirty, `task_status` reports
`target_dirty: true` and the orchestrator waits for the user. It never stashes.

### Flows

- **Triage:** `list_agents` → `read_pane` on waiting agents → `agent_respond`
  (shows a card when the target is not owned).
- **Dispatch:** `new_agent_task` ×N → loop on `wait_for_events` → on
  `needs-input` from an owned agent, respond directly.
- **Integrate:** on `task_finished`, call `task_status`:
  - dirty → tell the agent to commit
  - conflicts → tell the agent to rebase onto the target
  - target dirty → tell the user
  - clean → `task_diff` → summary → `merge_task` (card)

## 3. Gate, approvals, errors

### Capability tokens

- Each Boo-launched pane gets a random `BOO_TOKEN` next to `BOO_PANE_ID`,
  stored in memory only. There are two classes: **full** (normal panes) and
  **gated** (the orchestrator).
- **Sensitive commands**:
  - `agent_respond`
  - `send_text` / `send_key` into an agent pane
  - `send_text` / `send_key` into a remote-session pane (SSH, container, VM)
  - `close_pane` on an agent pane
  - `merge_task`, `discard_task`
- A sensitive command with a full token runs. A gated token → approval card,
  unless the target is owned (merge and discard always get a card). No token →
  rejected.
- Non-sensitive commands work without a token, so external scripts keep working.
- The in-process remote-control server bypasses the check. It has its own
  bearer auth.
- **Honest scope:** the gate catches model mistakes and overreach. It is not a
  defense against a same-user attacker, who can read other processes' env
  (`KERN_PROCARGS2`). Local shell panes count as non-sensitive because the
  orchestrator's Bash already has the user's local power. The sensitive targets
  are exactly the ones where it would gain new power.

### Approval cards

- A gated call returns immediately: `{status: "pending", approval_id}`. The
  outcome arrives as an `approval_resolved` event (`allowed`, `denied`,
  `stale`). No call blocks, so `MCP_TOOL_TIMEOUT` is never hit.
- **Staleness:** each card captures the target's inbox `updated_at`. If the
  target changed state or closed before you decide, the card resolves `stale`
  and nothing is sent. This is the same guard remote approve uses.
- A card shows:
  - the action ("Approve permission prompt", "Type into pane", "Merge 4 commits")
  - the target (agent · workspace · window, click to jump)
  - the exact payload (the text to type, the agent's pending tool call, or the
    diff stat)
- Buttons: **Allow**, **Deny**, **Allow for this pane** (session only; never for
  merge or discard). Keys while the drawer has focus: ⌘↩ allows, ⎋ denies.
- When the drawer is closed: a badge count on the toggle, plus a system
  notification via `ActivityNotifier` that opens the drawer on the card.
- Cards never time out into "allow".

### Loop guard

If the orchestrator sends more than 3 consecutive writes to the same agent with
no inbox state change in between, Boo pauses its writes and shows a "possible
loop" card. The threshold matches `AgentTimeline.loopThreshold`.

### Errors

| Case | Behavior |
|---|---|
| `claude` not installed | Drawer empty state with install hint |
| `--resume` fails | Start fresh; note "previous conversation unavailable" |
| Orchestrator exits | Drawer shows **Resume** / **New conversation** |
| User closes an owned tab | Removed from the owned set; `pane_closed` event |
| Boo relaunch | Owned tabs restored by tab ID; pending approvals resolve `stale` |
| Merge fails | Error text returned to the model; no retry loop |

## 4. Testing

Unit tests (XCTest, `make test`), following the existing patterns:

- **`BooMCPServerTests`**, using the fake `send` closure: each new tool's
  message shape; `split_pane` without a target from the orchestrator errors;
  `new_agent_task` passes `repo`/`base`/`model`; the per-call timeout on
  `wait_for_events`.
- **`OrchestratorGateTests`**: the full sensitive-command × token-class ×
  ownership matrix; merge and discard always produce a card; tokenless
  sensitive commands are rejected; tokenless reads work; the remote-control
  bypass.
- **`OrchestratorEventsTests`**: `since` semantics (no lost events between
  calls), immediate return when an event is pending, timeout returns `[]`, ring
  overflow.
- **`AgentInboxTests`**: orchestrator-role events are excluded from lists and
  jumps; ownership survives a serialize/restore round trip.
- **`ApprovalTests`**: a stale `updated_at` resolves `stale` and sends nothing;
  "allow for this pane" scope; loop-guard trigger.
- **`AgentWorktreeTests`**: a dirty main checkout blocks merge; the
  `merge-tree` conflict check on a real temp repo.

Manual checks:

- Drawer reparenting across windows: the pty survives and no plugin sees a
  terminal-closed event.
- The holder window when every window is closed.
- `--resume` after relaunch.
- The full dispatch → integrate run with two conflicting tasks.

## Implementation order

1. Capability tokens and the gate in the socket path.
2. `OrchestratorPane` and app-level routing in `WindowManager`.
3. Event ring and `wait_for_events`, plus the per-call client timeout.
4. MCP tool changes and new tools, plus the merge dirty-check fix.
5. Drawer UI: strip, cards, terminal host, reparenting, holder window.
6. Launch, the bundled prompt, persistence and `--resume`.
7. Loop guard, notifications, error states, docs page.
