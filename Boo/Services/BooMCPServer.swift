import Foundation

/// MCP server over stdio (`Boo --mcp`, or `~/.boo/shell-integration/boo-mcp`):
/// lets a coding agent running in a Boo terminal open panes beside itself, run
/// commands in them, read other panes and hand work to other agents.
///
/// Speaks newline-delimited JSON-RPC 2.0 and forwards each tool call to the Boo
/// socket. Pane arguments default to the agent's own pane: `BOO_PANE_ID` is set
/// in every Boo terminal and the agent passes its environment on to this process.
struct BooMCPServer {
    typealias Send = ([String: Any]) throws -> [String: Any]

    /// Sends one socket command and returns Boo's reply.
    let send: Send
    /// The pane the agent runs in, if it runs in Boo.
    let ownPaneID: String?
    /// The agent's working directory: default cwd for new panes and the repo for new tasks.
    let cwd: String
    /// `BOO_TOKEN` of the agent's terminal, sent with every command so Boo
    /// knows who asks (some commands are refused without it).
    var token: String? = nil

    static let protocolVersion = "2025-06-18"

    struct Failure: Error {
        let message: String
    }

    /// Seconds to wait for Boo's reply: `wait_for_events` is held by Boo for up
    /// to its own `timeout`, everything else answers at once.
    static func clientTimeout(for message: [String: Any]) -> Int {
        guard message["cmd"] as? String == "wait_for_events" else { return 10 }
        let held = (message["timeout"] as? Double) ?? (message["timeout"] as? Int).map(Double.init)
        return Int(min(max(held ?? OrchestratorEvents.defaultTimeout, 0), OrchestratorEvents.maxTimeout)) + 15
    }

    // MARK: - Stdio loop

    static func runStdio() -> Never {
        let env = ProcessInfo.processInfo.environment
        let socketPath =
            env["BOO_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".boo/boo.sock")
        let server = BooMCPServer(
            send: { try BooSocketClient.request($0, socketPath: socketPath, timeout: clientTimeout(for: $0)) },
            ownPaneID: env["BOO_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 },
            cwd: FileManager.default.currentDirectoryPath,
            token: env["BOO_TOKEN"].flatMap { $0.isEmpty ? nil : $0 })
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let response: [String: Any]?
            if let data = line.data(using: .utf8),
                let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                response = server.handle(message)
            } else {
                response = errorResponse(id: NSNull(), code: -32700, message: "parse error")
            }
            guard let response,
                let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
            else { continue }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(0)
    }

    // MARK: - JSON-RPC

    /// The response to one message; nil for notifications and client responses.
    func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return Self.result(
                id: id,
                [
                    "protocolVersion": requested ?? Self.protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "boo", "version": Self.version],
                    "instructions": Self.instructions
                ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name })
            else {
                return Self.errorResponse(id: id, code: -32602, message: "unknown tool: \(params["name"] ?? "")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return Self.result(id: id, ["content": [["type": "text", "text": try call(name, arguments)]]])
            } catch {
                let message = (error as? Failure)?.message ?? error.localizedDescription
                return Self.result(id: id, ["content": [["type": "text", "text": message]], "isError": true])
            }
        default:
            return Self.errorResponse(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Tools

    private func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "get_layout":
            var message: [String: Any] = ["cmd": "get_layout"]
            if let scope = args["scope"] as? String { message["scope"] = scope }
            var reply = try boo(message, pane: args["pane_id"] as? String ?? ownPaneID)
            reply["your_pane"] = ownPaneID ?? NSNull()
            return Self.json(reply)
        case "split_pane":
            var message: [String: Any] = [
                "cmd": "split_pane", "direction": args["direction"] as? String ?? "right",
                "focus": args["focus"] as? Bool ?? false, "cwd": args["cwd"] as? String ?? cwd
            ]
            if let command = args["command"] as? String { message["command"] = command }
            let reply = try boo(message, pane: args["pane_id"] as? String ?? ownPaneID)
            var out: [String: Any] = ["pane_id": reply["pane_id"] ?? NSNull()]
            if reply["started"] as? Bool == false {
                out["note"] =
                    "The workspace is in the background; the pane's shell (and command) starts when the user opens it."
            }
            return Self.json(out)
        case "read_pane":
            let lines = (args["lines"] as? Int) ?? 100
            if let tab = args["tab_id"] as? String, !tab.isEmpty {
                return try boo(["cmd": "get_screen", "lines": lines, "tab_id": tab], pane: nil)["text"] as? String ?? ""
            }
            let pane = try requiredPane(args, orTab: true)
            let reply = try boo(["cmd": "get_screen", "lines": lines], pane: pane)
            return reply["text"] as? String ?? ""
        case "send_text":
            let pane = try requiredPane(args, notOwn: "Refusing to type into your own pane.")
            guard let text = args["text"] as? String else { throw Failure(message: "text is required") }
            let reply = try boo(
                ["cmd": "send_text", "text": text, "submit": args["submit"] as? Bool ?? true], pane: pane)
            return Self.pending(reply) ?? "sent"
        case "close_pane":
            let pane = try requiredPane(args, notOwn: "Refusing to close your own pane.")
            let reply = try boo(["cmd": "close_pane"], pane: pane)
            return Self.pending(reply) ?? "closed"
        case "list_agents":
            return Self.json(try boo(["cmd": "agent_inbox"], pane: nil))
        case "new_agent_task":
            let repo = (args["repo"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cwd
            var message: [String: Any] = ["cmd": "new_agent_task", "repo": repo]
            for key in ["name", "prompt", "agent", "base", "model"] { message[key] = args[key] }
            let reply = try boo(message, pane: nil)
            var out: [String: Any] = [:]
            for key in ["tab_id", "workspace_id", "path", "branch"] { out[key] = reply[key] ?? NSNull() }
            return Self.json(out)
        case "open_review":
            _ = try boo(["cmd": "review_changes"], pane: args["pane_id"] as? String ?? ownPaneID)
            return "opened"
        case "wait_for_events":
            var message: [String: Any] = ["cmd": "wait_for_events"]
            for key in ["since", "timeout"] { message[key] = args[key] }
            return Self.json(try boo(message, pane: nil))
        case "agent_respond":
            var message: [String: Any] = ["cmd": "agent_respond", "tab_id": try requiredTab(args)]
            if let text = args["text"] as? String, args["response"] == nil {
                message["text"] = text
            } else {
                guard let response = args["response"] as? String else {
                    throw Failure(message: "response (approve or deny) or text is required")
                }
                message["response"] = response
                if let shown = args["updated_at"] { message["updated_at"] = shown }
            }
            return Self.pending(try boo(message, pane: nil)) ?? "sent"
        case "focus_pane":
            _ = try boo(["cmd": "agent_jump", "tab_id": try requiredTab(args)], pane: nil)
            return "focused"
        case "task_status":
            return Self.json(try boo(["cmd": "task_status", "tab_id": try requiredTab(args)], pane: nil))
        case "task_diff":
            let message: [String: Any] = [
                "cmd": "task_diff", "tab_id": try requiredTab(args), "stat_only": args["stat_only"] as? Bool ?? false
            ]
            return Self.json(try boo(message, pane: nil))
        case "merge_task", "discard_task":
            var message: [String: Any] = ["cmd": name, "tab_id": try requiredTab(args)]
            if name == "merge_task" {
                message["cleanup"] = args["cleanup"] as? Bool ?? true
                if let summary = args["summary"] as? String { message["summary"] = summary }
            }
            let reply = try boo(message, pane: nil)
            return Self.pending(reply) ?? Self.json(reply)
        default:
            throw Failure(message: "unknown tool: \(name)")
        }
    }

    /// What to tell the agent when Boo put the command on an approval card.
    private static func pending(_ reply: [String: Any]) -> String? {
        guard reply["status"] as? String == "pending" else { return nil }
        let id = reply["approval_id"] as? String ?? ""
        return
            "Waiting for the user to approve (approval_id \(id)). The outcome arrives as an approval_resolved event from wait_for_events; do not repeat the call."
    }

    /// Sends `message` aimed at `pane` and unwraps Boo's `ok`/`error` reply.
    private func boo(_ message: [String: Any], pane: String?) throws -> [String: Any] {
        var message = message
        if let pane { message["pane_id"] = pane }
        if let token { message["token"] = token }
        var reply = try send(message)
        guard reply["ok"] as? Bool == true else {
            throw Failure(message: reply["error"] as? String ?? "Boo refused \(message["cmd"] ?? "the command")")
        }
        reply.removeValue(forKey: "ok")
        return reply
    }

    private func requiredPane(_ args: [String: Any], notOwn refusal: String? = nil, orTab: Bool = false) throws
        -> String
    {
        guard let pane = args["pane_id"] as? String, !pane.isEmpty else {
            throw Failure(message: "\(orTab ? "pane_id or tab_id" : "pane_id") is required (get_layout lists them)")
        }
        if let refusal, pane.caseInsensitiveCompare(ownPaneID ?? "") == .orderedSame {
            throw Failure(message: refusal)
        }
        return pane
    }

    private func requiredTab(_ args: [String: Any]) throws -> String {
        guard let tab = args["tab_id"] as? String, !tab.isEmpty else {
            throw Failure(message: "tab_id is required (get_layout with scope app lists them)")
        }
        return tab
    }

    private static func json(_ value: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static let instructions = """
        Boo is the terminal you are running in. Use these tools to work beside the user: \
        open a pane next to yours for a dev server, test watcher or log tail and read its output \
        later, instead of blocking your own shell. New panes leave focus with the user. \
        get_layout shows every pane, its tabs and running processes; your_pane is yours; \
        scope app covers every window. new_agent_task hands independent work to another agent \
        on its own worktree; wait_for_events blocks until agents change state, so loop on it \
        (pass the last seq as since) instead of polling. task_status says whether a task can \
        merge and why not; merge_task and discard_task always wait for the user's approval.
        """

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static var paneProperty: [String: Any] {
        ["type": "string", "description": "Pane id from get_layout"]
    }

    private static var tabProperty: [String: Any] {
        ["type": "string", "description": "Tab id of an agent, from get_layout (scope app) or list_agents"]
    }

    static var tools: [[String: Any]] {
        [
            [
                "name": "get_layout",
                "description":
                    "Panes of the Boo workspace you run in: split tree, and each pane's tabs with title, cwd and running process. your_pane is the pane you are in. With scope app: every window, workspace, pane and tab, each agent's state and whether you started it (owned).",
                "inputSchema": object([
                    "pane_id": paneProperty,
                    "scope": [
                        "type": "string", "enum": ["workspace", "app"],
                        "description": "workspace (default) or the whole app"
                    ]
                ]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "split_pane",
                "description":
                    "Opens a terminal pane beside yours (or beside pane_id) and optionally runs a command in it, e.g. a dev server, test watcher or `tail -f`. Focus stays where it is unless focus is true. Returns the new pane_id; read its output with read_pane.",
                "inputSchema": object([
                    "direction": [
                        "type": "string", "enum": ["right", "down", "left", "up"],
                        "description": "Side of the existing pane the new one opens on (default right)"
                    ],
                    "command": ["type": "string", "description": "Shell command to run in the new pane"],
                    "cwd": ["type": "string", "description": "Working directory (default: yours)"],
                    "pane_id": paneProperty,
                    "focus": ["type": "boolean", "description": "Move keyboard focus to the new pane (default false)"]
                ])
            ],
            [
                "name": "read_pane",
                "description":
                    "Reads the last lines of a terminal's output, scrollback included: a pane's active tab, or any tab by tab_id in any window.",
                "inputSchema": object([
                    "pane_id": paneProperty,
                    "tab_id": tabProperty,
                    "lines": ["type": "integer", "description": "How many lines (default 100, max 5000)"]
                ]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "send_text",
                "description":
                    "Types text into another pane. With submit (default true) it is pasted as one input and Return is pressed: runs a shell command, or sends a prompt to an agent in that pane.",
                "inputSchema": object(
                    [
                        "pane_id": paneProperty,
                        "text": ["type": "string"],
                        "submit": ["type": "boolean", "description": "Press Return after the text (default true)"]
                    ], required: ["pane_id", "text"])
            ],
            [
                "name": "close_pane",
                "description": "Closes a pane and whatever runs in it. Not your own pane.",
                "inputSchema": object(["pane_id": paneProperty], required: ["pane_id"]),
                "annotations": ["destructiveHint": true]
            ],
            [
                "name": "list_agents",
                "description": "Coding agents running in any Boo window and their state (working, needs input, done).",
                "inputSchema": object([:]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "new_agent_task",
                "description":
                    "Starts another coding agent on its own git worktree and branch (boo/<name>) of a repository, in a new Boo workspace, with prompt as its first message. For independent work that can run in parallel. Returns the agent's tab_id.",
                "inputSchema": object(
                    [
                        "name": ["type": "string", "description": "Short task name, used for the branch"],
                        "prompt": ["type": "string", "description": "First message for the agent"],
                        "repo": ["type": "string", "description": "Repository path (default: your cwd)"],
                        "base": [
                            "type": "string", "description": "Branch or commit to start from (default: the repo's HEAD)"
                        ],
                        "agent": [
                            "type": "string", "enum": ["claude", "codex", "opencode"],
                            "description": "Which agent (default claude)"
                        ],
                        "model": ["type": "string", "description": "Model for the agent (default: its own)"]
                    ], required: ["prompt"])
            ],
            [
                "name": "open_review",
                "description":
                    "Opens Boo's review of a workspace's changes for the user (yours, or pane_id's), who can comment on lines and send the comments back to the agent as one message.",
                "inputSchema": object(["pane_id": paneProperty])
            ],
            [
                "name": "wait_for_events",
                "description":
                    "Blocks until something happens (an agent changes state, a task is spawned or finishes, a pane closes, an approval resolves) or timeout passes, then returns the events and seq. Pass the last seq as since so nothing is lost between calls; missed true means older events were dropped, so re-read get_layout.",
                "inputSchema": object([
                    "since": ["type": "integer", "description": "Return events after this seq (default: now)"],
                    "timeout": ["type": "number", "description": "Seconds to wait (default 300, max 540)"]
                ]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "agent_respond",
                "description":
                    "Answers an agent: approve or deny the permission prompt it waits on, or send it text as a message (for an agent that is not waiting on a prompt). Needs the user's approval unless you started the agent.",
                "inputSchema": object(
                    [
                        "tab_id": tabProperty,
                        "response": ["type": "string", "enum": ["approve", "deny"]],
                        "text": ["type": "string", "description": "A message instead of approve or deny"],
                        "updated_at": [
                            "type": "number",
                            "description":
                                "The agent's updated_at you looked at, so the answer never lands on a newer prompt"
                        ]
                    ], required: ["tab_id"])
            ],
            [
                "name": "focus_pane",
                "description": "Brings an agent's tab to the front for the user, in whatever window it is.",
                "inputSchema": object(["tab_id": tabProperty], required: ["tab_id"])
            ],
            [
                "name": "task_status",
                "description":
                    "Whether an agent task can merge: branch, target, commits ahead and behind, uncommitted changes in the task or the main checkout, files that would conflict, and blocker with a hint when it cannot.",
                "inputSchema": object(["tab_id": tabProperty], required: ["tab_id"]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "task_diff",
                "description":
                    "An agent task's changes against its target branch: files with line counts and, unless stat_only, the diff.",
                "inputSchema": object(
                    [
                        "tab_id": tabProperty,
                        "stat_only": ["type": "boolean", "description": "Only the file list (default false)"]
                    ], required: ["tab_id"]),
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "merge_task",
                "description":
                    "Merges an agent task's branch into the main checkout's branch, after the user approves. Check task_status first. With cleanup (default true) the workspace, worktree and branch are removed after.",
                "inputSchema": object(
                    [
                        "tab_id": tabProperty,
                        "cleanup": ["type": "boolean", "description": "Remove the task after merging (default true)"],
                        "summary": ["type": "string", "description": "One line for the user's approval card"]
                    ], required: ["tab_id"]),
                "annotations": ["destructiveHint": true]
            ],
            [
                "name": "discard_task",
                "description":
                    "Closes an agent task and deletes its worktree and branch, after the user approves. Unmerged work is lost.",
                "inputSchema": object(["tab_id": tabProperty], required: ["tab_id"]),
                "annotations": ["destructiveHint": true]
            ]
        ]
    }
}

/// Minimal blocking client for the Boo socket: one JSON line out, one back.
enum BooSocketClient {
    static func request(_ message: [String: Any], socketPath: String, timeout: Int = 10) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BooMCPServer.Failure(message: "socket() failed") }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw BooMCPServer.Failure(message: "socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw BooMCPServer.Failure(message: "Boo is not running (no socket at \(socketPath)).")
        }

        var payload = try JSONSerialization.data(withJSONObject: message)
        payload.append(UInt8(ascii: "\n"))
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw BooMCPServer.Failure(message: "could not write to Boo") }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while response.last != UInt8(ascii: "\n") {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            response.append(chunk, count: count)
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else {
            throw BooMCPServer.Failure(message: "no reply from Boo")
        }
        return reply
    }
}
