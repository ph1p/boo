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

    // MARK: - Stdio loop

    static func runStdio() -> Never {
        let env = ProcessInfo.processInfo.environment
        let socketPath =
            env["BOO_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".boo/boo.sock")
        let server = BooMCPServer(
            send: { try BooSocketClient.request($0, socketPath: socketPath) },
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
            var reply = try boo(["cmd": "get_layout"], pane: args["pane_id"] as? String ?? ownPaneID)
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
            let pane = try requiredPane(args)
            let lines = (args["lines"] as? Int) ?? 100
            let reply = try boo(["cmd": "get_screen", "lines": lines], pane: pane)
            return reply["text"] as? String ?? ""
        case "send_text":
            let pane = try requiredPane(args, notOwn: "Refusing to type into your own pane.")
            guard let text = args["text"] as? String else { throw Failure(message: "text is required") }
            _ = try boo(["cmd": "send_text", "text": text, "submit": args["submit"] as? Bool ?? true], pane: pane)
            return "sent"
        case "close_pane":
            let pane = try requiredPane(args, notOwn: "Refusing to close your own pane.")
            _ = try boo(["cmd": "close_pane"], pane: pane)
            return "closed"
        case "list_agents":
            return Self.json(try boo(["cmd": "agent_inbox"], pane: nil))
        case "new_agent_task":
            var message: [String: Any] = ["cmd": "new_agent_task", "repo": cwd]
            for key in ["name", "prompt", "agent"] { message[key] = args[key] }
            let reply = try boo(message, pane: nil)
            return Self.json(["path": reply["path"] ?? NSNull(), "workspace_id": reply["workspace_id"] ?? NSNull()])
        case "open_review":
            _ = try boo(["cmd": "review_changes"], pane: ownPaneID)
            return "opened"
        default:
            throw Failure(message: "unknown tool: \(name)")
        }
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

    private func requiredPane(_ args: [String: Any], notOwn refusal: String? = nil) throws -> String {
        guard let pane = args["pane_id"] as? String, !pane.isEmpty else {
            throw Failure(message: "pane_id is required (get_layout lists the panes)")
        }
        if let refusal, pane.caseInsensitiveCompare(ownPaneID ?? "") == .orderedSame {
            throw Failure(message: refusal)
        }
        return pane
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
        get_layout shows every pane, its tabs and running processes; your_pane is yours.
        """

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static var paneProperty: [String: Any] {
        ["type": "string", "description": "Pane id from get_layout"]
    }

    static var tools: [[String: Any]] {
        [
            [
                "name": "get_layout",
                "description":
                    "Panes of the Boo workspace you run in: split tree, and each pane's tabs with title, cwd and running process. your_pane is the pane you are in.",
                "inputSchema": object(["pane_id": paneProperty]),
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
                "description": "Reads the last lines of a pane's terminal output, scrollback included.",
                "inputSchema": object(
                    [
                        "pane_id": paneProperty,
                        "lines": ["type": "integer", "description": "How many lines (default 100, max 5000)"]
                    ], required: ["pane_id"]),
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
                    "Starts another coding agent on its own git worktree and branch (boo/<name>) of your repository, in a new Boo workspace, with prompt as its first message. For independent work that can run in parallel; the user merges or discards it.",
                "inputSchema": object(
                    [
                        "name": ["type": "string", "description": "Short task name, used for the branch"],
                        "prompt": ["type": "string", "description": "First message for the agent"],
                        "agent": [
                            "type": "string", "enum": ["claude", "codex", "opencode"],
                            "description": "Which agent (default claude)"
                        ]
                    ], required: ["prompt"])
            ],
            [
                "name": "open_review",
                "description":
                    "Opens Boo's review of this workspace's changes for the user, who can comment on lines and send the comments back to you as one message.",
                "inputSchema": object([:])
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
