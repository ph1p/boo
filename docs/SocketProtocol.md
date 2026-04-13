# Boo Socket Protocol

Unix domain socket for IPC between terminal processes and Boo.

**Socket path**: `~/.boo/boo.sock` (also in `$BOO_SOCK`)  
**Format**: Newline-delimited JSON (one JSON object per line)  
**Direction**: Client → Boo for commands; Boo → Client for responses and push events  
**Auth**: Same-UID check on connect (kernel-level, no tokens needed)  
**Limit**: 128 concurrent clients

---

## Message Format

### Request
```json
{"cmd": "<command>", ...params}
```

### Response
```json
{"ok": true, ...result}
{"ok": false, "error": "description"}
```

### Push event (after subscribing)
```json
{"event": "<name>", "data": {...}}
```

---

## Built-in Commands

### Status Registration

Processes register themselves so Boo can show them in the sidebar status area and identify them as the foreground process.

#### `set_status`
Register a process.
```json
{"cmd": "set_status", "pid": 12345, "name": "claude", "category": "ai", "metadata": {"session": "abc"}}
```
- `pid` — process ID (verified alive)
- `name` — display name
- `category` — `"ai"` | `"build"` | `"test"` | `"server"` | `"unknown"`
- `metadata` — optional string key/value map

#### `clear_status`
Unregister a process.
```json
{"cmd": "clear_status", "pid": 12345}
```

#### `list_status`
List all registered processes.
```json
{"cmd": "list_status"}
```
Response:
```json
{"ok": true, "processes": [{"pid": 12345, "name": "claude", "category": "ai"}]}
```

---

### Query Commands

#### `get_context`
Current terminal context snapshot.
```json
{"cmd": "get_context"}
```
Response fields: `cwd`, `title`, `process`, `remote_session`, `remote_cwd`, `pane_id`, `workspace_id`

#### `get_theme`
Current theme info.
```json
{"cmd": "get_theme"}
```
Response fields: `name`, `is_dark`, `background`, `foreground`, `accent`

#### `get_settings`
Selected app settings.
```json
{"cmd": "get_settings"}
```
Response fields: `font_name`, `font_size`, `theme_name`, `sidebar_visible`

#### `list_themes`
All available theme names.
```json
{"cmd": "list_themes"}
```
Response: `{"ok": true, "themes": ["Dracula", "Nord", ...]}`

#### `get_workspaces`
List all open workspaces.
```json
{"cmd": "get_workspaces"}
```
Response: `{"ok": true, "workspaces": [{"index": 0, "id": "...", "path": "/...", "name": "...", "is_active": true, "pane_count": 2}]}`

---

### Control Commands

These are routed to the main window controller on the main thread.

#### `set_theme`
```json
{"cmd": "set_theme", "name": "Dracula"}
```

#### `toggle_sidebar`
```json
{"cmd": "toggle_sidebar"}
```
Response: `{"ok": true, "visible": true}`

#### `switch_workspace`
```json
{"cmd": "switch_workspace", "index": 1}
{"cmd": "switch_workspace", "id": "<uuid>"}
```

#### `new_tab`
```json
{"cmd": "new_tab", "cwd": "/optional/path"}
```

#### `new_workspace`
```json
{"cmd": "new_workspace", "path": "/optional/path"}
```

#### `send_text`
Write raw text to the active terminal (no newline appended).
```json
{"cmd": "send_text", "text": "ls -la\n"}
```

---

### Subscriptions

Subscribe to receive push events from Boo without polling.

#### `subscribe`
```json
{"cmd": "subscribe", "events": ["cwd_changed", "process_changed"]}
{"cmd": "subscribe", "events": ["*"]}
```
- `"*"` subscribes to all events.

#### `unsubscribe`
```json
{"cmd": "unsubscribe", "events": ["cwd_changed"]}
```

---

### Status Bar Segments (Plugin Namespace)

External processes can push custom segments to the Boo status bar.

#### `statusbar.set`
```json
{"cmd": "statusbar.set", "id": "my-tool", "text": "● running", "color": "#00FF88"}
```

#### `statusbar.clear`
```json
{"cmd": "statusbar.clear", "id": "my-tool"}
```

#### `statusbar.list`
```json
{"cmd": "statusbar.list"}
```

---

### Plugin Namespace Routing

Plugins can register custom command handlers under a namespace prefix.

```
{"cmd": "myplugin.action", ...}
```

Routes to the handler registered for namespace `"myplugin"`. The full JSON dict is passed to the handler; the return dict is sent as the response.

---

## Push Events

Subscribe with `subscribe` to receive these as they happen.

| Event | Data fields |
|-------|-------------|
| `cwd_changed` | `path`, `is_remote`, `pane_id` |
| `title_changed` | `title`, `pane_id` |
| `process_changed` | `name`, `category`?, `pane_id` |
| `remote_session_changed` | `active`, `type`?, `host`?, `user`?, `pane_id` |
| `focus_changed` | `pane_id` |
| `workspace_switched` | `workspace_id` |
| `theme_changed` | `name`, `is_dark` |
| `settings_changed` | `topic` |
| `cmd_started` | `command`, `pane_id` |
| `cmd_ended` | `command`, `exit_code`, `duration`, `pane_id` |

`cmd_started` and `cmd_ended` require the user to source Boo's shell integration:
```bash
source ~/.boo/shell-integration/boo.bash  # or boo.zsh / boo.fish
```

---

## Shell Integration

Boo ships integration scripts for bash, zsh, and fish at `~/.boo/shell-integration/`. These are installed/updated automatically on startup.

Scripts use OSC 2 SET_TITLE sequences prefixed with `BOO_CMD:` to report command lifecycle events. Boo intercepts these before they reach the title bar.

### Installation

**bash** — add to `~/.bashrc` or `~/.bash_profile`:
```bash
source ~/.boo/shell-integration/boo.bash
```

**zsh** — add to `~/.zshrc`:
```zsh
source ~/.boo/shell-integration/boo.zsh
```

**fish** — add to `~/.config/fish/config.fish` or symlink as a conf.d snippet:
```fish
source ~/.boo/shell-integration/boo.fish
# or: ln -s ~/.boo/shell-integration/boo.fish ~/.config/fish/conf.d/boo.fish
```

Detection: `$BOO_SHELL_INTEGRATION` is set to the shell name when active.

---

## Client Example (bash)

```bash
BOO_SOCK="${BOO_SOCK:-$HOME/.boo/boo.sock}"

boo_cmd() {
    echo "$1" | nc -U "$BOO_SOCK"
}

# Get current context
boo_cmd '{"cmd":"get_context"}'

# Subscribe to CWD changes (persistent connection)
{
    echo '{"cmd":"subscribe","events":["cwd_changed","cmd_ended"]}'
    sleep infinity
} | nc -U "$BOO_SOCK"
```

## Client Example (Python)

```python
import socket, json, os

sock_path = os.environ.get("BOO_SOCK", os.path.expanduser("~/.boo/boo.sock"))

def boo_cmd(cmd_dict):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.sendall((json.dumps(cmd_dict) + "\n").encode())
    response = b""
    while b"\n" not in response:
        response += s.recv(4096)
    s.close()
    return json.loads(response.split(b"\n")[0])

print(boo_cmd({"cmd": "get_context"}))
```
