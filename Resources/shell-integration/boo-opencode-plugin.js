// Boo agent plugin for OpenCode. Boo copies it to OpenCode's global plugin
// folder on launch, so edits there are overwritten.
//
// Reports what OpenCode does to Boo's agent inbox (as boo-claude-hook does for
// Claude Code) and tells the agent about the `boo` CLI. Does nothing outside a
// Boo terminal or while agents are off in Boo's settings (~/.boo/agents-disabled).
import { existsSync } from "node:fs"
import { createConnection } from "node:net"
import { homedir } from "node:os"
import { join } from "node:path"

const DISABLED_FLAG = join(homedir(), ".boo", "agents-disabled")

// Keep in sync with CREW_CONTEXT in boo-claude-hook.
const CREW_CONTEXT = `You run in a tab of Boo, a terminal app for coding agents. When the user \
wants another agent (a helper beside you, parallel work, a second opinion), start a real \
one with the \`boo\` CLI instead of an in-process subagent, so the user can watch and talk to it:
- boo run --here "<prompt>": helper in a tab next to yours (your crew group), same folder.
- boo run "<prompt>": helper on its own git worktree and branch (for code changes).
- boo agents: every agent with its handle (t1, t2...) and state; "(you)" marks your own tab.
- boo wait <handle>: blocks until it finishes its turn, prints its answer (exit 3: it asks a question).
- boo send <handle> <text>: message it; delivered when it finishes its turn.
- boo read <handle>: its screen.
- boo diff / boo merge / boo discard <handle>: review a \`boo run\` task, merge its branch into the main checkout (closes it), or throw it away. Use these instead of git merge; ask the user before merging or discarding.
Helpers report back to you on their own in a <boo from=... state=...> message, and close when \
your tab closes. \`boo help\` lists the rest.`

function active() {
  return Boolean(process.env.BOO_SOCK && process.env.BOO_PANE_ID) && !existsSync(DISABLED_FLAG)
}

/** Sends one agent_event to Boo's socket. Never throws, gives up after 2s. */
function report(event, fields = {}) {
  if (!active()) return Promise.resolve()
  const msg = { cmd: "agent_event", pane_id: process.env.BOO_PANE_ID, event, agent: "opencode" }
  if (process.env.BOO_TAB_ID) msg.tab_id = process.env.BOO_TAB_ID
  for (const [key, value] of Object.entries(fields)) if (value) msg[key] = value
  return new Promise((resolve) => {
    try {
      const socket = createConnection(process.env.BOO_SOCK)
      const done = () => {
        socket.destroy()
        resolve()
      }
      socket.setTimeout(2000, done)
      socket.on("error", done)
      socket.on("data", done)
      socket.on("connect", () => socket.write(JSON.stringify(msg) + "\n"))
    } catch {
      resolve()
    }
  })
}

export const BooPlugin = async ({ client, directory }) => {
  // The agent's last answer: reported to the agent that started it.
  const lastReply = async (sessionID) => {
    try {
      const res = await client.session.messages({ path: { id: sessionID } })
      const list = Array.isArray(res) ? res : (res?.data ?? [])
      for (let i = list.length - 1; i >= 0; i--) {
        if (list[i]?.info?.role !== "assistant") continue
        const text = (list[i].parts ?? [])
          .filter((part) => part?.type === "text")
          .map((part) => part.text)
          .join("\n")
          .trim()
        if (text) return text.length <= 4000 ? text : text.slice(0, 4000) + "\n..."
      }
    } catch {}
    return undefined
  }

  return {
    event: async ({ event }) => {
      const props = event?.properties ?? {}
      switch (event?.type) {
        case "session.created":
          return report("start", { session_id: props.info?.id, cwd: directory })
        case "session.idle":
          if (!active()) return
          return report("stop", {
            session_id: props.sessionID,
            reply: await lastReply(props.sessionID),
            cwd: directory,
          })
        case "permission.updated":
        case "permission.asked":
          return report("permission", {
            message: props.title || "needs your permission",
            session_id: props.sessionID,
          })
      }
    },
    "chat.message": async (input) => report("prompt", { session_id: input?.sessionID, cwd: directory }),
    "tool.execute.before": async (input, output) => {
      if (input?.tool === "question") {
        const question = output?.args?.questions?.[0]?.question
        return report("question", {
          message: question || "has a question",
          tool: "question",
          session_id: input.sessionID,
        })
      }
      return report("tool", { tool: input?.tool, session_id: input?.sessionID })
    },
    "experimental.chat.system.transform": async (_input, output) => {
      if (active() && Array.isArray(output?.system) && !output.system.includes(CREW_CONTEXT)) {
        output.system.push(CREW_CONTEXT)
      }
    },
  }
}
