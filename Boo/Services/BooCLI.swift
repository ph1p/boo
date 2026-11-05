import Foundation

/// `boo`: the agent crew from any shell or script in a Boo terminal
/// (`~/.boo/bin/boo`, which runs `Boo --cli`). Any process can join: a
/// script can start a helper agent and the helper's answer comes back to it.
///
///     boo agents                          list agents with handles
///     boo run [--here] [--agent codex] [--name N] [--model M] "prompt"
///     boo send t3 "text"                  message an agent (or `parent`)
///     boo inbox                           read messages waiting for this tab
///     boo wait t3                         block until t3 finishes its turn
///     boo read t3 [--lines N]             print t3's screen
///     boo status working|blocked|done|error [message]
///     boo diff t3 | merge t3 [--keep] | discard t3   a task's worktree
enum BooCLI {
    struct Output: Equatable {
        var text: String
        var status: Int32
    }

    static let usage = """
        usage: boo <command> [args]

          agents                       Agents in every Boo window, with handles (t1, t2, ...)
          run [options] <prompt>       Start an agent that reports back to this tab
              --here                   In a tab next to this one instead of its own worktree
              --agent claude|codex|opencode
              --name <name>            Task name (branch boo/<name>)
              --model <model>
              --base <branch>          Branch the worktree starts from (default: HEAD)
          send <to> <text>             Message an agent: a handle (t3), parent, or tab id.
                                       Delivered when it finishes its current turn.
          inbox                        Read and clear messages waiting for this tab
          wait <agent> [--timeout S]   Block until the agent finishes its turn, asks or exits;
                                       prints its answer. Exit 0 done, 1 error/exited, 3 asks,
                                       124 timed out
          read <agent> [--lines N]     Print the agent's screen (default 60 lines)
          status <state> [message]     Report this tab's state: working, blocked, done, error

        Tasks started with `boo run` (their own worktree and branch):
          diff <agent> [--stat]        Print what the task changed
          merge <agent> [--keep]       Merge its branch into the main checkout's branch and close
                                       it (--keep leaves the tab and worktree)
          discard <agent>              Close it and delete its worktree and branch
        """

    /// Entry point for `Boo --cli`; never returns.
    static func runAndExit(arguments: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let socketPath =
            env["BOO_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".boo/boo.sock")
        let output = run(
            arguments, env: env, cwd: FileManager.default.currentDirectoryPath,
            send: { try BooSocketClient.request($0, socketPath: socketPath, timeout: 60) })
        let handle = output.status == 0 ? FileHandle.standardOutput : FileHandle.standardError
        if !output.text.isEmpty { handle.write(Data((output.text + "\n").utf8)) }
        exit(output.status)
    }

    static func run(
        _ arguments: [String], env: [String: String], cwd: String,
        send: ([String: Any]) throws -> [String: Any],
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Output {
        guard let command = arguments.first else { return Output(text: usage, status: 2) }
        var rest = Array(arguments.dropFirst())
        let pane = env["BOO_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let tab = env["BOO_TAB_ID"].flatMap { $0.isEmpty ? nil : $0 }

        /// `fromPane: false` for commands that target another tab, where the
        /// caller's pane would route the command to the caller instead.
        func request(_ message: [String: Any], fromPane: Bool = true) throws -> [String: Any] {
            var message = message
            if fromPane, let pane, message["pane_id"] == nil { message["pane_id"] = pane }
            if let token = env["BOO_TOKEN"], !token.isEmpty { message["token"] = token }
            let reply = try send(message)
            guard reply["ok"] as? Bool == true else {
                throw BooMCPServer.Failure(message: reply["error"] as? String ?? "Boo refused \(message["cmd"] ?? "")")
            }
            return reply
        }

        do {
            switch command {
            case "agents", "ls":
                return Output(text: agentsTable(try request(["cmd": "agent_inbox"]), you: tab), status: 0)
            case "run":
                var message: [String: Any] = ["cmd": "new_agent_task", "repo": cwd]
                while let flag = rest.first, flag.hasPrefix("--") {
                    rest.removeFirst()
                    switch flag {
                    case "--here":
                        message["worktree"] = false
                        message["cwd"] = cwd
                    case "--agent", "--name", "--model", "--base":
                        guard !rest.isEmpty else { return Output(text: "\(flag) needs a value", status: 2) }
                        message[String(flag.dropFirst(2))] = rest.removeFirst()
                    case "--":
                        break
                    default:
                        return Output(text: "unknown option \(flag)\n\n\(usage)", status: 2)
                    }
                    if flag == "--" { break }
                }
                let prompt = rest.joined(separator: " ")
                guard !prompt.isEmpty else { return Output(text: "missing prompt\n\n\(usage)", status: 2) }
                message["prompt"] = prompt
                let reply = try request(message)
                if reply["status"] as? String == "pending" {
                    return Output(text: "waiting for your approval in Boo", status: 0)
                }
                let handle = reply["handle"] as? String ?? "?"
                let place = (reply["branch"] as? String).map { " on \($0)" } ?? " next to this tab"
                return Output(text: "started \(handle)\(place); it reports back here when done", status: 0)
            case "send":
                guard rest.count >= 2 else { return Output(text: "usage: boo send <to> <text>", status: 2) }
                let to = rest.removeFirst()
                let reply = try request(["cmd": "agent_send", "to": to, "text": rest.joined(separator: " ")])
                if reply["status"] as? String == "pending" {
                    return Output(text: "waiting for your approval in Boo", status: 0)
                }
                let label = reply["to"] as? String ?? to
                return Output(
                    text: reply["status"] as? String == "queued"
                        ? "queued for \(label) (delivered when it finishes its turn)" : "sent to \(label)",
                    status: 0)
            case "inbox":
                let reply = try request(["cmd": "agent_messages"])
                let messages = (reply["messages"] as? [[String: Any]] ?? []).map {
                    AgentCrew.Message(
                        from: $0["from"] as? String ?? "?", state: $0["state"] as? String,
                        text: $0["text"] as? String ?? "")
                }
                return Output(text: AgentCrew.envelope(messages), status: 0)
            case "wait":
                var args = rest
                guard let seconds = takeValue("--timeout", from: &args) else {
                    return Output(text: "--timeout needs seconds", status: 2)
                }
                guard let target = args.first else {
                    return Output(text: "usage: boo wait <agent> [--timeout S]", status: 2)
                }
                var timeout: TimeInterval?
                if let seconds {
                    guard let value = TimeInterval(seconds), value >= 0 else {
                        return Output(text: "--timeout needs seconds", status: 2)
                    }
                    timeout = value
                }
                let output = try wait(
                    for: target, caller: tab, timeout: timeout, poll: { try request(["cmd": "agent_inbox"]) },
                    sleep: sleep)
                // The caller has the answer now; its queued report would repeat it.
                if output.status != 124 { _ = try? request(["cmd": "agent_collected", "tab_id": target]) }
                return output
            case "read":
                var args = rest
                guard let count = takeValue("--lines", from: &args) else {
                    return Output(text: "--lines needs a number", status: 2)
                }
                guard let target = args.first else {
                    return Output(text: "usage: boo read <agent> [--lines N]", status: 2)
                }
                var lines = 60
                if let count {
                    guard let value = Int(count), value > 0 else {
                        return Output(text: "--lines needs a number", status: 2)
                    }
                    lines = value
                }
                let reply = try request(["cmd": "get_screen", "tab_id": target, "lines": lines], fromPane: false)
                return Output(text: reply["text"] as? String ?? "", status: 0)
            case "status":
                let states = ["working": "working", "blocked": "needs-input", "done": "done", "error": "error"]
                guard let state = rest.first, let event = states[state] else {
                    return Output(text: "usage: boo status working|blocked|done|error [message]", status: 2)
                }
                guard pane != nil else { return Output(text: "run this inside a Boo terminal", status: 1) }
                var message: [String: Any] = [
                    "cmd": "agent_event", "event": event, "agent": env["BOO_AGENT"] ?? "script"
                ]
                if let tab { message["tab_id"] = tab }
                let text = rest.dropFirst().joined(separator: " ")
                if !text.isEmpty { message[event == "done" ? "reply" : "message"] = text }
                _ = try request(message)
                return Output(text: "", status: 0)
            case "diff":
                guard let target = rest.first else {
                    return Output(text: "usage: boo diff <agent> [--stat]", status: 2)
                }
                let stat = rest.dropFirst().contains("--stat")
                let reply = try request(["cmd": "task_diff", "tab_id": target, "stat_only": stat], fromPane: false)
                return Output(text: diffText(reply), status: 0)
            case "merge":
                guard let target = rest.first else {
                    return Output(text: "usage: boo merge <agent> [--keep]", status: 2)
                }
                let keep = rest.dropFirst().contains("--keep")
                let reply = try request(["cmd": "merge_task", "tab_id": target, "cleanup": !keep], fromPane: false)
                let commits = reply["merged"] as? Int ?? 0
                let into = (reply["target"] as? String).map { " into \($0)" } ?? ""
                let closed = keep ? "" : "; its tab and worktree are closed"
                return Output(text: "merged \(commits) commit\(commits == 1 ? "" : "s")\(into)\(closed)", status: 0)
            case "discard":
                guard let target = rest.first else { return Output(text: "usage: boo discard <agent>", status: 2) }
                _ = try request(["cmd": "discard_task", "tab_id": target], fromPane: false)
                return Output(text: "discarded \(target): its worktree and branch are deleted", status: 0)
            case "help", "-h", "--help":
                return Output(text: usage, status: 0)
            default:
                return Output(text: "unknown command \(command)\n\n\(usage)", status: 2)
            }
        } catch let failure as BooMCPServer.Failure {
            return Output(text: "boo: \(failure.message)", status: 1)
        } catch {
            return Output(text: "boo: \(error.localizedDescription)", status: 1)
        }
    }

    /// Polls `agent_inbox` until `target` stops working. A turn that ended before
    /// the agent was seen working counts once it stays idle for `settle` seconds,
    /// so `boo run` then `boo wait` does not return the previous turn's state.
    static func wait(
        for target: String, caller: String? = nil, timeout: TimeInterval?, poll: () throws -> [String: Any],
        sleep: (TimeInterval) -> Void, interval: TimeInterval = 1, settle: TimeInterval = 3,
        freshSettle: TimeInterval = 60
    ) throws -> Output {
        let reference = target.lowercased()
        var wanted = target
        if Int(reference) != nil {
            wanted = "t" + reference
        } else if reference.hasPrefix("t"), Int(reference.dropFirst()) != nil {
            wanted = reference
        }
        var waited: TimeInterval = 0
        var sawWorking = false
        var sawAgent = false
        while true {
            let rows = (try poll())["items"] as? [[String: Any]] ?? []
            if reference == "parent" {
                // The caller's row names its parent's handle; once found, a parent
                // that disappears has exited.
                if let caller, let own = rows.first(where: { ($0["tab_id"] as? String) == caller }),
                    let parent = own["parent"] as? String
                {
                    wanted = parent
                } else if !sawAgent {
                    return Output(text: "this tab has no parent agent", status: 1)
                }
            }
            let row = rows.first { ($0["handle"] as? String) == wanted || ($0["tab_id"] as? String) == target }
            if let row {
                sawAgent = true
                if let handle = row["handle"] as? String { wanted = handle }
                let state = row["state"] as? String ?? ""
                // A fresh row has not had a turn yet: a new helper still starting up.
                let fresh = row["fresh"] as? Bool == true
                if state == "working" {
                    sawWorking = true
                } else if sawWorking || waited >= (fresh ? freshSettle : settle) {
                    func text(_ key: String) -> String { row[key] as? String ?? "" }
                    switch state {
                    case "done" where fresh: return Output(text: "\(wanted) idles at its prompt", status: 0)
                    case "done": return Output(text: text("reply").isEmpty ? text("message") : text("reply"), status: 0)
                    case "needs-input": return Output(text: "\(wanted) asks: \(text("message"))", status: 3)
                    default: return Output(text: "\(wanted) stopped: \(text("message"))", status: 1)
                    }
                }
            } else if sawAgent {
                return Output(text: "\(wanted) exited", status: 1)
            } else if waited >= 30 {
                return Output(text: "no agent \(target) (boo agents lists handles)", status: 1)
            }
            if let timeout, waited >= timeout { return Output(text: "timed out waiting for \(wanted)", status: 124) }
            sleep(interval)
            waited += interval
        }
    }

    /// Removes `name value` from `args` wherever it appears. Returns `.some(nil)`
    /// when the option is absent and nil when it has no value.
    static func takeValue(_ name: String, from args: inout [String]) -> String?? {
        if let index = args.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            let value = String(args.remove(at: index).dropFirst(name.count + 1))
            return value.isEmpty ? nil : .some(value)
        }
        guard let index = args.firstIndex(of: name) else { return .some(nil) }
        guard index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return .some(value)
    }

    /// `+3 -1 calc.py` per file, then the diff unless it was `--stat`.
    static func diffText(_ reply: [String: Any]) -> String {
        let files = reply["files"] as? [[String: Any]] ?? []
        guard !files.isEmpty else { return "no changes" }
        var lines = files.map { file in
            "+\(file["additions"] as? Int ?? 0) -\(file["deletions"] as? Int ?? 0) \(file["path"] as? String ?? "?")"
        }
        if let diff = reply["diff"] as? String, !diff.isEmpty {
            lines.append("")
            lines.append(diff.hasSuffix("\n") ? String(diff.dropLast()) : diff)
            if reply["truncated"] as? Bool == true { lines.append("[diff truncated]") }
        }
        return lines.joined(separator: "\n")
    }

    /// `t1  working      fix-tests      parent t0` rows, crew first. `you` is
    /// the caller's tab: an agent does not know its own tab's title.
    static func agentsTable(_ reply: [String: Any], you: String? = nil) -> String {
        let rows = (reply["items"] as? [[String: Any]] ?? reply["agents"] as? [[String: Any]] ?? [])
        guard !rows.isEmpty else { return "no agents" }
        func number(_ row: [String: Any]) -> Int { Int((row["handle"] as? String ?? "").dropFirst()) ?? 0 }
        // A tab outside every window has no title: say which agent and where.
        func name(_ row: [String: Any]) -> String {
            if let name = row["name"] as? String, !name.isEmpty { return name }
            let folder = (row["cwd"] as? String).map { " in " + ($0 as NSString).lastPathComponent } ?? ""
            return (row["agent"] as? String ?? "agent") + folder
        }
        return rows.sorted { number($0) < number($1) }.map { row in
            var line = [
                (row["handle"] as? String ?? "?").padding(toLength: 4, withPad: " ", startingAt: 0),
                (row["state"] as? String ?? "").padding(toLength: 12, withPad: " ", startingAt: 0),
                name(row)
            ].joined(separator: " ")
            if let you, row["tab_id"] as? String == you { line += "  (you)" }
            if let parent = row["parent"] as? String { line += "  (from \(parent))" }
            if let queued = row["queued"] as? Int, queued > 0 { line += "  [\(queued) queued]" }
            return line
        }.joined(separator: "\n")
    }
}
