# Boo agent plugin for Hermes. Boo copies it to ~/.hermes/plugins/boo/__init__.py
# on launch, so edits there are overwritten.
#
# Reports what Hermes does to Boo's agent inbox (as boo-claude-hook does for
# Claude Code) and tells the agent about the `boo` CLI. Does nothing outside a
# Boo terminal or while agents are off in Boo's settings (~/.boo/agents-disabled).
#
# Hermes has no flag that starts an interactive session with a prompt, so Boo
# starts it as `_BOO_FIRST_PROMPT=<prompt> hermes chat` and this plugin types
# the prompt in once the CLI is up.
import json
import os
import socket
import threading
import time

DISABLED_FLAG = os.path.join(os.path.expanduser("~"), ".boo", "agents-disabled")

# Keep in sync with CREW_CONTEXT in boo-claude-hook.
CREW_CONTEXT = """You run in a tab of Boo, a terminal app for coding agents. When the user \
wants another agent (a helper beside you, parallel work, a second opinion), start a real \
one with the `boo` CLI instead of an in-process subagent, so the user can watch and talk to it:
- boo run --here "<prompt>": helper in a tab next to yours (your crew group), same folder.
- boo run "<prompt>": helper on its own git worktree and branch (for code changes).
- boo agents: every agent with its handle (t1, t2...) and state; "(you)" marks your own tab.
- boo wait <handle>: blocks until it finishes its turn, prints its answer (exit 3: it asks a question).
- boo send <handle> <text>: message it; delivered when it finishes its turn.
- boo read <handle>: its screen.
- boo diff / boo merge / boo discard <handle>: review a `boo run` task, merge its branch into the main checkout (closes it), or throw it away. Use these instead of git merge; ask the user before merging or discarding.
Helpers report back to you on their own in a <boo from=... state=...> message, and close when \
your tab closes. `boo help` lists the rest."""


def _active():
    return bool(os.environ.get("BOO_SOCK") and os.environ.get("BOO_PANE_ID")) and not os.path.exists(DISABLED_FLAG)


def _report(event, **fields):
    """Sends one agent_event to Boo's socket. Never raises, gives up after 2s."""
    if not _active():
        return
    msg = {"cmd": "agent_event", "pane_id": os.environ["BOO_PANE_ID"], "event": event, "agent": "hermes"}
    if os.environ.get("BOO_TAB_ID"):
        msg["tab_id"] = os.environ["BOO_TAB_ID"]
    for key, value in fields.items():
        if value:
            msg[key] = value
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(os.environ["BOO_SOCK"])
        s.sendall(json.dumps(msg).encode() + b"\n")
        s.recv(256)
        s.close()
    except Exception:
        pass


def _reply(text):
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    return text if len(text) <= 4000 else text[:4000] + "\n..."


def _on_session_start(session_id=None, **_):
    _report("start", session_id=session_id, cwd=os.getcwd())


def _pre_llm_call(session_id=None, **_):
    _report("prompt", session_id=session_id, cwd=os.getcwd())
    if _active():
        return {"context": CREW_CONTEXT}
    return None


def _pre_tool_call(tool_name=None, args=None, session_id=None, **_):
    if tool_name == "clarify":
        question = (args or {}).get("question") if isinstance(args, dict) else None
        _report("question", message=question or "has a question", tool=tool_name, session_id=session_id)
    else:
        _report("tool", tool=tool_name, session_id=session_id)


def _post_llm_call(session_id=None, assistant_response=None, **_):
    _report("stop", session_id=session_id, reply=_reply(assistant_response), cwd=os.getcwd())


def _on_session_finalize(session_id=None, **_):
    _report("end", session_id=session_id)


def _type_first_prompt(ctx, prompt):
    """Queues Boo's prompt as the first message once the CLI has started."""
    manager = getattr(ctx, "_manager", None)
    for _ in range(600):  # up to 60s
        if manager is not None and getattr(manager, "_cli_ref", None) is not None:
            try:
                ctx.inject_message(prompt)
            except Exception:
                pass
            return
        time.sleep(0.1)


def register(ctx):
    ctx.register_hook("on_session_start", _on_session_start)
    ctx.register_hook("pre_llm_call", _pre_llm_call)
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    ctx.register_hook("post_llm_call", _post_llm_call)
    ctx.register_hook("on_session_finalize", _on_session_finalize)

    prompt = os.environ.pop("_BOO_FIRST_PROMPT", "").strip()
    if prompt:
        threading.Thread(target=_type_first_prompt, args=(ctx, prompt), daemon=True).start()
