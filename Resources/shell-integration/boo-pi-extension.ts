// Boo agent extension for pi. Boo copies it to ~/.pi/agent/extensions/boo.ts
// on launch, so edits there are overwritten.
//
// Reports what pi does to Boo's agent inbox (as boo-claude-hook does for
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

function active(): boolean {
  return Boolean(process.env.BOO_SOCK && process.env.BOO_PANE_ID) && !existsSync(DISABLED_FLAG)
}

/** Sends one agent_event to Boo's socket. Never throws, gives up after 2s. */
function report(event: string, fields: Record<string, string | undefined> = {}): Promise<void> {
  if (!active()) return Promise.resolve()
  const msg: Record<string, string> = { cmd: "agent_event", pane_id: process.env.BOO_PANE_ID!, event, agent: "pi" }
  if (process.env.BOO_TAB_ID) msg.tab_id = process.env.BOO_TAB_ID
  for (const [key, value] of Object.entries(fields)) if (value) msg[key] = value
  return new Promise((resolve) => {
    try {
      const socket = createConnection(process.env.BOO_SOCK!)
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

function sessionID(ctx: any): string | undefined {
  try {
    return ctx?.sessionManager?.getSessionId?.() ?? undefined
  } catch {
    return undefined
  }
}

/** The agent's last answer: reported to the agent that started it. */
function lastReply(ctx: any): string | undefined {
  try {
    const entries: any[] = ctx?.sessionManager?.getBranch?.() ?? []
    for (let i = entries.length - 1; i >= 0; i--) {
      const message = entries[i]?.type === "message" ? entries[i].message : undefined
      if (message?.role !== "assistant") continue
      const content = message.content
      const text = (
        typeof content === "string"
          ? content
          : (Array.isArray(content) ? content : [])
              .filter((part: any) => part?.type === "text")
              .map((part: any) => part.text)
              .join("\n")
      ).trim()
      if (text) return text.length <= 4000 ? text : text.slice(0, 4000) + "\n..."
    }
  } catch {}
  return undefined
}

export default function (pi: any) {
  pi.on("session_start", async (_event: any, ctx: any) => {
    await report("start", { session_id: sessionID(ctx), cwd: ctx?.cwd })
  })
  pi.on("before_agent_start", async (event: any, ctx: any) => {
    await report("prompt", { session_id: sessionID(ctx), cwd: ctx?.cwd })
    if (!active() || typeof event?.systemPrompt !== "string" || event.systemPrompt.includes(CREW_CONTEXT)) return
    return { systemPrompt: event.systemPrompt + "\n\n" + CREW_CONTEXT }
  })
  pi.on("tool_execution_start", async (event: any, ctx: any) => {
    await report("tool", { tool: event?.toolName, session_id: sessionID(ctx) })
  })
  pi.on("agent_settled", async (_event: any, ctx: any) => {
    if (!active()) return
    await report("stop", { session_id: sessionID(ctx), reply: lastReply(ctx), cwd: ctx?.cwd })
  })
  pi.on("session_shutdown", async (_event: any, ctx: any) => {
    await report("end", { session_id: sessionID(ctx) })
  })
}
