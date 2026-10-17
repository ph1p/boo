import Foundation

/// What a Claude Code session did, read from its transcript
/// (`~/.claude/projects/<project>/<session>.jsonl`): one turn per prompt with
/// the tools it ran, the files it changed, tokens and cost. Repeated tool
/// calls are folded into one row with a count, so loops stand out.
struct AgentTimeline: Equatable {
    struct Usage: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0

        var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        var total: Int { input + output + cacheRead + cacheWrite }
        /// Tokens the model read for the request: the context size.
        var context: Int { input + cacheRead + cacheWrite }

        static func + (a: Usage, b: Usage) -> Usage {
            Usage(
                input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
        }
    }

    struct Tool: Equatable {
        var name: String
        /// Command, file, pattern or URL: what the call was about.
        var summary: String
        /// File the call changed (Edit, Write, MultiEdit, NotebookEdit).
        var file: String?
        /// Consecutive identical calls folded into this row.
        var count = 1
        var failures = 0

        /// Three or more identical calls in a row: likely stuck.
        var isLoop: Bool { count >= AgentTimeline.loopThreshold }
    }

    struct Turn: Identifiable, Equatable {
        enum Kind: Equatable {
            case prompt
            /// A slash command such as `/review`.
            case command
            /// The conversation was summarized to free context.
            case compacted
        }

        let id: Int
        var kind: Kind
        var prompt: String
        var start: Date?
        var end: Date?
        var tools: [Tool] = []
        /// The agent's last text in the turn.
        var reply: String?
        var usage = Usage()
        /// Context size of the turn's last request.
        var context = 0
        var cost = 0.0
        var model: String?
        var interrupted = false

        var duration: TimeInterval? { start.flatMap { s in end.map { $0.timeIntervalSince(s) } } }
        var toolCount: Int { tools.reduce(0) { $0 + $1.count } }
        var hasLoop: Bool { tools.contains(where: \.isLoop) }
    }

    var sessionID: String?
    var title: String?
    var cwd: String?
    var branch: String?
    var models: [String] = []
    var start: Date?
    var end: Date?
    var turns: [Turn] = []
    /// Tokens of the main conversation; subagents are counted in `subagentUsage`.
    var usage = Usage()
    var subagentUsage = Usage()
    var subagentCost = 0.0
    /// Changed files with the number of edits, most edited first.
    var files: [(path: String, edits: Int)] = []
    /// Total in USD: Claude's own figure once the session ended, else estimated
    /// from token counts.
    var cost = 0.0
    var costIsExact = false

    static let loopThreshold = 3

    var toolCount: Int { turns.reduce(0) { $0 + $1.toolCount } }
    var loopCount: Int { turns.reduce(0) { $0 + $1.tools.filter(\.isLoop).count } }

    static func == (a: AgentTimeline, b: AgentTimeline) -> Bool {
        a.sessionID == b.sessionID && a.title == b.title && a.turns == b.turns && a.usage == b.usage
            && a.subagentUsage == b.subagentUsage && a.cost == b.cost && a.costIsExact == b.costIsExact
            && a.files.map(\.path) == b.files.map(\.path) && a.files.map(\.edits) == b.files.map(\.edits)
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> AgentTimeline {
        let parser = Parser()
        parser.consume(data)
        parser.finish()
        return parser.timeline
    }

    static func parse(_ text: String) -> AgentTimeline { parse(Data(text.utf8)) }

    // MARK: - Transcripts

    /// Claude's config folder: `$CLAUDE_CONFIG_DIR` or `~/.claude`.
    static var claudeDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// The transcript of `sessionID`, whichever project folder it is in.
    static func transcriptURL(sessionID: String, claudeDirectory: URL = claudeDirectory) -> URL? {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
        let projects = claudeDirectory.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let url = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Subagent transcripts of a session: `<session>/subagents/*.jsonl`.
    static func subagentURLs(of transcript: URL) -> [URL] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { folder.appendingPathComponent($0) }
    }

    // MARK: - Pricing

    /// USD per million input tokens. Output costs 5×, cache reads 0.1×,
    /// 5-minute cache writes 1.25× and 1-hour cache writes 2×. First match wins.
    static let inputRates: [(model: String, rate: Double)] = [
        ("opus-4-1", 15), ("opus-4-0", 15), ("opus-4-2", 15), ("opus-4", 5), ("opus", 3),
        ("sonnet-4", 3), ("sonnet-3", 3), ("sonnet", 2),
        ("haiku-3", 0.8), ("haiku-4", 1), ("haiku", 0.1),
        ("fable", 7)
    ]

    static func estimatedCost(of usage: Usage, model: String?) -> Double {
        guard let model, let rate = inputRates.first(where: { model.contains($0.model) })?.rate else { return 0 }
        let weighted =
            Double(usage.input) + 5 * Double(usage.output) + 0.1 * Double(usage.cacheRead) + 1.25
            * Double(usage.cacheWrite5m) + 2 * Double(usage.cacheWrite1h)
        return weighted * rate / 1_000_000
    }
}

// MARK: - Parser

extension AgentTimeline {
    /// Reads a transcript line by line. Feed it the file as it grows with
    /// `consume`; `timeline` is current after each call.
    final class Parser {
        private(set) var timeline = AgentTimeline()
        private var pending = Data()
        /// Usage per API message: a message is written over several lines
        /// that repeat its usage, so only the last one counts.
        private var messageUsage: [String: (turn: Int, usage: Usage, model: String?, order: Int)] = [:]
        private var toolIndex: [String: (turn: Int, tool: Int)] = [:]
        private var fileEdits: [String: Int] = [:]
        private var exactCost: Double?
        private var assistantAfterCostState = false

        func consume(_ data: Data) {
            pending.append(data)
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = pending[pending.startIndex..<lastNewline]
            pending = Data(pending[(lastNewline + 1)...])
            for line in complete.split(separator: UInt8(ascii: "\n")) { read(line) }
            summarize()
        }

        /// Reads a last line without a newline.
        func finish() {
            guard !pending.isEmpty else { return }
            read(pending[...])
            pending = Data()
            summarize()
        }

        private static let wanted: [Data] = [
            "\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"ai-title\"", "\"type\":\"cost-state\""
        ].map { Data($0.utf8) }

        private func read(_ line: Data.SubSequence) {
            // Most lines (request dumps, snapshots) are large and unused.
            guard Self.wanted.contains(where: { line.range(of: $0) != nil }),
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = object["type"] as? String
            else { return }
            switch type {
            case "ai-title":
                if let title = object["aiTitle"] as? String, !title.isEmpty { timeline.title = title }
            case "cost-state":
                if let cost = object["totalCostUSD"] as? Double {
                    exactCost = cost
                    assistantAfterCostState = false
                }
            case "user", "assistant":
                guard object["isSidechain"] as? Bool != true else { return }
                note(object)
                if type == "user" { readUser(object) } else { readAssistant(object) }
            default:
                break
            }
        }

        private func note(_ object: [String: Any]) {
            if timeline.sessionID == nil { timeline.sessionID = object["sessionId"] as? String }
            if let cwd = object["cwd"] as? String { timeline.cwd = cwd }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty { timeline.branch = branch }
            if let date = (object["timestamp"] as? String).flatMap(Self.date) {
                if timeline.start == nil { timeline.start = date }
                timeline.end = date
                if !timeline.turns.isEmpty { timeline.turns[timeline.turns.count - 1].end = date }
            }
        }

        // MARK: User lines

        private func readUser(_ object: [String: Any]) {
            let message = object["message"] as? [String: Any]
            let date = (object["timestamp"] as? String).flatMap(Self.date)
            if object["isCompactSummary"] as? Bool == true {
                startTurn(.compacted, "Continued after compacting the context", date)
                return
            }
            if let text = message?["content"] as? String {
                readPrompt(text, object: object, date: date)
                return
            }
            guard let blocks = message?["content"] as? [[String: Any]] else { return }
            var text: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    if block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String,
                        let at = toolIndex[id]
                    {
                        timeline.turns[at.turn].tools[at.tool].failures += 1
                    }
                case "text":
                    if let string = block["text"] as? String { text.append(string) }
                default:
                    break
                }
            }
            if !text.isEmpty { readPrompt(text.joined(separator: "\n"), object: object, date: date) }
        }

        private func readPrompt(_ text: String, object: [String: Any], date: Date?) {
            if object["isMeta"] as? Bool == true { return }
            if let origin = (object["origin"] as? [String: Any])?["kind"] as? String, origin != "human" { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[Request interrupted") {
                if !timeline.turns.isEmpty { timeline.turns[timeline.turns.count - 1].interrupted = true }
                return
            }
            if trimmed.hasPrefix("<command-name>") {
                let name = Self.tag("command-name", in: trimmed) ?? ""
                let args = Self.tag("command-args", in: trimmed) ?? ""
                // Commands that only change the UI (/clear, /model...) leave no turn.
                startTurn(.command, args.isEmpty ? name : "\(name) \(args)", date)
                return
            }
            if trimmed.isEmpty || trimmed.hasPrefix("<local-command") || trimmed.hasPrefix("<task-notification")
                || trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("<bash-")
            {
                return
            }
            startTurn(.prompt, Self.collapsePastes(in: trimmed), date)
        }

        private static let pastePattern = try! NSRegularExpression(
            pattern: "<pasted_content[^>]*>([\\s\\S]*?)</pasted_content>")

        /// Pasted blocks become "[pasted 12 lines]" so the prompt stays readable.
        static func collapsePastes(in text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            var result = text
            for match in pastePattern.matches(in: text, range: range).reversed() {
                guard let whole = Range(match.range, in: result), let body = Range(match.range(at: 1), in: text)
                else { continue }
                let lines = text[body].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                    .count
                result.replaceSubrange(whole, with: "[pasted \(lines) line\(lines == 1 ? "" : "s")]")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func startTurn(_ kind: Turn.Kind, _ prompt: String, _ date: Date?) {
            // A command that did nothing (/clear, /model) is replaced by what follows.
            if let last = timeline.turns.last, last.kind == .command, last.usage.total == 0, last.tools.isEmpty,
                last.reply == nil
            {
                timeline.turns.removeLast()
            }
            timeline.turns.append(Turn(id: timeline.turns.count, kind: kind, prompt: prompt, start: date, end: date))
        }

        // MARK: Assistant lines

        private func readAssistant(_ object: [String: Any]) {
            guard let message = object["message"] as? [String: Any] else { return }
            if timeline.turns.isEmpty {
                let date = (object["timestamp"] as? String).flatMap(Self.date)
                timeline.turns.append(Turn(id: 0, kind: .prompt, prompt: "", start: date, end: date))
            }
            let turn = timeline.turns.count - 1
            let model = (message["model"] as? String).flatMap { $0.hasPrefix("<") ? nil : $0 }
            if let model {
                timeline.turns[turn].model = model
                if !timeline.models.contains(model) { timeline.models.append(model) }
            }
            if let id = message["id"] as? String, let usage = (message["usage"] as? [String: Any]).map(Self.usage) {
                let previous = messageUsage[id]
                messageUsage[id] = (previous?.turn ?? turn, usage, model, previous?.order ?? messageUsage.count)
                assistantAfterCostState = true
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    {
                        timeline.turns[turn].reply = text
                    }
                case "tool_use":
                    guard let id = block["id"] as? String, toolIndex[id] == nil else { continue }
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    addTool(Self.tool(name: name, input: input), id: id, turn: turn)
                default:
                    break
                }
            }
        }

        private func addTool(_ tool: Tool, id: String, turn: Int) {
            if let file = tool.file { fileEdits[file, default: 0] += 1 }
            var tools = timeline.turns[turn].tools
            if let last = tools.last, last.name == tool.name, last.summary == tool.summary {
                tools[tools.count - 1].count += 1
            } else {
                tools.append(tool)
            }
            timeline.turns[turn].tools = tools
            toolIndex[id] = (turn, tools.count - 1)
        }

        // MARK: Totals

        private func summarize() {
            var turnUsage: [Int: Usage] = [:]
            var turnCost: [Int: Double] = [:]
            var total = Usage()
            var estimate = 0.0
            for entry in messageUsage.values {
                turnUsage[entry.turn] = (turnUsage[entry.turn] ?? Usage()) + entry.usage
                let cost = AgentTimeline.estimatedCost(of: entry.usage, model: entry.model)
                turnCost[entry.turn, default: 0] += cost
                total = total + entry.usage
                estimate += cost
            }
            timeline.usage = total
            estimate += timeline.subagentCost
            // Claude's figure covers the whole session once it ended; turns get
            // their share of it by estimated cost.
            let exact = assistantAfterCostState ? nil : exactCost
            let scale = exact.map { estimate > 0 ? $0 / estimate : 0 } ?? 1
            timeline.cost = exact ?? estimate
            timeline.costIsExact = exact != nil
            for index in timeline.turns.indices {
                timeline.turns[index].usage = turnUsage[index] ?? Usage()
                timeline.turns[index].cost = (turnCost[index] ?? 0) * scale
            }
            // Context of a turn: its last request's input.
            var last: [Int: (order: Int, context: Int)] = [:]
            for entry in messageUsage.values where entry.order >= (last[entry.turn]?.order ?? -1) {
                last[entry.turn] = (entry.order, entry.usage.context)
            }
            for (turn, value) in last { timeline.turns[turn].context = value.context }
            timeline.files = fileEdits.map { (path: $0.key, edits: $0.value) }
                .sorted { $0.edits != $1.edits ? $0.edits > $1.edits : $0.path < $1.path }
        }

        private var subagents: [String: (usage: Usage, cost: Double)] = [:]

        /// Counts a subagent transcript's tokens in the session, replacing what
        /// was read from `key` before.
        func setSubagent(_ key: String, _ data: Data) {
            var usage: [String: (Usage, String?)] = [:]
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let message = object["message"] as? [String: Any], let id = message["id"] as? String,
                    let values = message["usage"] as? [String: Any]
                else { continue }
                usage[id] = (Self.usage(values), message["model"] as? String)
            }
            subagents[key] = usage.values.reduce((Usage(), 0.0)) { sum, entry in
                (sum.0 + entry.0, sum.1 + AgentTimeline.estimatedCost(of: entry.0, model: entry.1))
            }
            timeline.subagentUsage = subagents.values.reduce(Usage()) { $0 + $1.usage }
            timeline.subagentCost = subagents.values.reduce(0) { $0 + $1.cost }
            summarize()
        }

        // MARK: Helpers

        private static func usage(_ values: [String: Any]) -> Usage {
            func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
            var usage = Usage(
                input: int(values["input_tokens"]), output: int(values["output_tokens"]),
                cacheRead: int(values["cache_read_input_tokens"]))
            let write = int(values["cache_creation_input_tokens"])
            if let split = values["cache_creation"] as? [String: Any] {
                usage.cacheWrite1h = int(split["ephemeral_1h_input_tokens"])
                usage.cacheWrite5m = max(0, write - usage.cacheWrite1h)
            } else {
                usage.cacheWrite5m = write
            }
            return usage
        }

        static func tool(name: String, input: [String: Any]) -> Tool {
            func string(_ key: String) -> String? {
                guard let value = input[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            let editors: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
            let path = string("file_path") ?? string("notebook_path")
            let summary: String
            switch name {
            case "Bash":
                summary = string("command") ?? string("description") ?? ""
            case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
                summary = path ?? ""
            case "Grep", "Glob":
                summary = [string("pattern"), string("path")].compactMap { $0 }.joined(separator: "  in ")
            case "WebFetch":
                summary = string("url") ?? ""
            case "WebSearch":
                summary = string("query") ?? ""
            case "Agent", "Task":
                summary = string("description") ?? string("prompt") ?? ""
            case "Skill":
                summary = string("skill") ?? ""
            default:
                summary =
                    input.keys.sorted().lazy.compactMap { key in
                        (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    }
                    .first ?? ""
            }
            let line = summary.components(separatedBy: "\n").first ?? summary
            return Tool(
                name: name, summary: line.count > 240 ? String(line.prefix(239)) + "…" : line,
                file: editors.contains(name) ? path : nil)
        }

        private static func tag(_ name: String, in text: String) -> String? {
            guard let open = text.range(of: "<\(name)>"),
                let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

        static func date(_ string: String) -> Date? { fractional.date(from: string) ?? plain.date(from: string) }
    }
}

// MARK: - Socket

extension AgentTimeline {
    /// JSON for `agent_timeline`: totals plus the last `turns` prompts.
    func serialize(turns limit: Int) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func tokens(_ usage: Usage) -> [String: Any] {
            [
                "input": usage.input, "output": usage.output, "cache_read": usage.cacheRead,
                "cache_write": usage.cacheWrite
            ]
        }
        var result: [String: Any] = [
            "ok": true, "prompts": turns.count, "tool_calls": toolCount, "loops": loopCount,
            "cost": (cost * 10000).rounded() / 10000, "cost_exact": costIsExact, "models": models,
            "tokens": tokens(usage), "subagent_tokens": tokens(subagentUsage),
            "files": files.map { ["path": $0.path, "edits": $0.edits] }
        ]
        result["session_id"] = sessionID
        result["title"] = title
        result["cwd"] = cwd
        result["branch"] = branch
        result["start"] = start.map(iso.string)
        result["end"] = end.map(iso.string)
        result["turns"] = turns.suffix(max(0, limit)).map { turn -> [String: Any] in
            var entry: [String: Any] = [
                "kind": "\(turn.kind)", "prompt": String(turn.prompt.prefix(500)), "tool_calls": turn.toolCount,
                "failed": turn.tools.reduce(0) { $0 + $1.failures }, "cost": (turn.cost * 10000).rounded() / 10000,
                "output_tokens": turn.usage.output, "context": turn.context, "interrupted": turn.interrupted,
                "loops": turn.tools.filter(\.isLoop).map {
                    ["tool": $0.name, "summary": $0.summary, "count": $0.count]
                }
            ]
            entry["start"] = turn.start.map(iso.string)
            entry["duration"] = turn.duration.map { ($0 * 10).rounded() / 10 }
            entry["reply"] = turn.reply.map { String($0.prefix(500)) }
            return entry
        }
        return result
    }
}

extension AgentInbox {
    /// `agent_timeline {tab_id | session_id, turns?, open?}`: what the session did;
    /// `open` also shows it in a tab.
    func timeline(_ json: [String: Any]) -> [String: Any] {
        let tabID = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:))
        guard let sessionID = json["session_id"] as? String ?? tabID.flatMap({ items[$0]?.sessionID }) else {
            return ["ok": false, "error": tabID == nil ? "missing tab_id or session_id" : "no session for this tab"]
        }
        guard let url = AgentTimeline.transcriptURL(sessionID: sessionID),
            let timeline = AgentTimelineStore.shared.load(url)
        else { return ["ok": false, "error": "no transcript for session \(sessionID)"] }
        if json["open"] as? Bool == true {
            let label =
                tabID.flatMap { items[$0] }.map { AgentHandoff.label(for: $0) } ?? timeline.title ?? "Claude Code"
            WindowManager.shared.activeController?.openTimeline(sessionID: sessionID, label: label)
        }
        return timeline.serialize(turns: (json["turns"] as? Int) ?? 10)
    }
}

// MARK: - Store

/// One parser per transcript; each load reads only what was appended since
/// the last one, so a live session's timeline stays cheap to refresh.
final class AgentTimelineStore: @unchecked Sendable {
    static let shared = AgentTimelineStore()

    private struct Entry {
        let parser = AgentTimeline.Parser()
        var offset: UInt64 = 0
        var subagentSizes: [String: UInt64] = [:]
        var used = Date()
    }

    private let queue = DispatchQueue(label: "boo.agent-timeline")
    private var entries: [String: Entry] = [:]
    private let maxEntries = 8

    /// The transcript's timeline, read from disk as far as it is written.
    func load(_ url: URL) -> AgentTimeline? {
        queue.sync { read(url) }
    }

    private func read(_ url: URL) -> AgentTimeline? {
        let path = url.path
        guard let size = Self.size(of: path) else {
            entries[path] = nil
            return nil
        }
        var entry = entries[path] ?? Entry()
        if size < entry.offset { entry = Entry() }  // rewritten
        if size > entry.offset, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: entry.offset)
            if let data = try? handle.read(upToCount: Int(size - entry.offset)) {
                entry.parser.consume(data)
                entry.offset += UInt64(data.count)
            }
        }
        for subagent in AgentTimeline.subagentURLs(of: url) {
            let key = subagent.lastPathComponent
            guard let size = Self.size(of: subagent.path), size != entry.subagentSizes[key],
                let data = FileManager.default.contents(atPath: subagent.path)
            else { continue }
            entry.parser.setSubagent(key, data)
            entry.subagentSizes[key] = size
        }
        entry.used = Date()
        entries[path] = entry
        if entries.count > maxEntries, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
        return entry.parser.timeline
    }

    private static func size(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }
}
