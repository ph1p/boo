import Foundation

extension Notification.Name {
    static let agentCostsChanged = Notification.Name("BooAgentCostsChanged")
}

/// One API response of a Claude Code session, priced at list rates.
struct AgentCostRecord: Equatable {
    var time: Date
    /// Model ID as Claude Code wrote it, e.g. `claude-opus-4-5-20251101`.
    var model: String
    /// The session's working directory; empty when unknown.
    var project: String
    var session: String
    var subagent: Bool
    var cost: Double
}

/// Estimated spend over a period, split by project, model and day.
struct AgentCostSummary: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        var cost: Double
    }

    struct Day: Equatable {
        let start: Date
        var cost: Double
    }

    var total = 0.0
    var subagents = 0.0
    var sessions = 0
    /// Most expensive first.
    var projects: [Row] = []
    var models: [Row] = []
    /// One per day of the period, oldest first.
    var days: [Day] = []

    /// Sums the records of the `dayCount` days that end with `now`'s day.
    init(_ records: [AgentCostRecord], days dayCount: Int, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<max(1, dayCount)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard let first = starts.first else { return }
        var byDay: [Date: Double] = [:]
        var byProject: [String: Double] = [:]
        var byModel: [String: Double] = [:]
        var sessions = Set<String>()
        for record in records where record.time >= first {
            total += record.cost
            if record.subagent { subagents += record.cost }
            sessions.insert(record.session)
            byDay[calendar.startOfDay(for: record.time), default: 0] += record.cost
            byProject[record.project, default: 0] += record.cost
            byModel[Self.modelName(record.model), default: 0] += record.cost
        }
        self.sessions = sessions.count
        days = starts.map { Day(start: $0, cost: byDay[$0] ?? 0) }
        projects = Self.rows(byProject, names: Self.projectNames(byProject.keys))
        models = Self.rows(byModel, names: [:])
    }

    /// Rows that cost at least a cent (models served elsewhere cost nothing).
    private static func rows(_ costs: [String: Double], names: [String: String]) -> [Row] {
        costs.filter { $0.value >= 0.005 }.map { Row(id: $0.key, name: names[$0.key] ?? $0.key, cost: $0.value) }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.name < $1.name }
    }

    /// The folder name, with its parent when two projects share it.
    static func projectNames(_ paths: some Collection<String>) -> [String: String] {
        let short = { (path: String) in path.isEmpty ? "Unknown" : (path as NSString).lastPathComponent }
        var counts: [String: Int] = [:]
        for path in paths { counts[short(path), default: 0] += 1 }
        var names: [String: String] = [:]
        for path in paths {
            let name = short(path)
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            names[path] = counts[name, default: 0] > 1 && !parent.isEmpty ? parent + "/" + name : name
        }
        return names
    }

    /// `claude-opus-4-5-20251101` → `Opus 4.5`, `claude-3-5-sonnet-20241022`
    /// → `Sonnet 3.5`; other IDs unchanged.
    static func modelName(_ id: String) -> String {
        let base = id.lowercased().split(separator: "[").first.map(String.init) ?? id
        let parts = base.split(separator: "-").map(String.init)
        guard let family = parts.first(where: { ["opus", "sonnet", "haiku", "fable"].contains($0) }) else { return id }
        let version = parts.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

/// Estimated cost of every Claude Code session of the last 30 days, read
/// from all transcripts under `~/.claude/projects` (subagents included), not
/// only the agents open in Boo. Reads only what was appended since the last
/// scan; what was read is cached in `~/.boo/agent-costs.plist`.
@MainActor
final class AgentCostLedger {
    static let shared = AgentCostLedger()
    nonisolated static let retentionDays = 30

    private(set) var records: [AgentCostRecord] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private var refreshAgain = false
    private var completions: [@MainActor () -> Void] = []
    private let scanner = Scanner(
        projects: AgentTimeline.claudeDirectory.appendingPathComponent("projects"),
        cache: URL(fileURLWithPath: (BooPaths.configDir as NSString).appendingPathComponent("agent-costs.plist")))

    /// Estimated cost of every session since `start`.
    func total(since start: Date) -> Double {
        records.reduce(0) { $1.time >= start ? $0 + $1.cost : $0 }
    }

    /// Rescans in the background, then calls `completion` and posts
    /// `.agentCostsChanged`. While cost tracking is off it only calls `completion`.
    func refresh(completion: (@MainActor () -> Void)? = nil) {
        if let completion { completions.append(completion) }
        guard AppSettings.shared.agentCostTracking else {
            finish()
            return
        }
        guard !isScanning else {
            refreshAgain = true
            return
        }
        isScanning = true
        NotificationCenter.default.post(name: .agentCostsChanged, object: self)
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async {
            let records = scanner.scan(now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ledger = AgentCostLedger.shared
                    ledger.isScanning = false
                    ledger.lastScan = Date()
                    ledger.records = AppSettings.shared.agentCostTracking ? records : []
                    if ledger.refreshAgain {
                        ledger.refreshAgain = false
                        ledger.refresh()
                    } else {
                        ledger.finish()
                    }
                }
            }
        }
    }

    private func finish() {
        let pending = completions
        completions = []
        for completion in pending { completion() }
        NotificationCenter.default.post(name: .agentCostsChanged, object: self)
    }

    /// Frees what was read once tracking is turned off (the disk cache stays,
    /// so turning it back on does not rescan everything).
    func unload() {
        guard !records.isEmpty || lastScan != nil else { return }
        records = []
        lastScan = nil
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async { scanner.unload() }
        NotificationCenter.default.post(name: .agentCostsChanged, object: self)
    }
}

// MARK: - Scanner

extension AgentCostLedger {
    /// Reads transcripts on a background thread. Only one scan runs at a time
    /// (`AgentCostLedger.isScanning`), the lock guards `unload` against it.
    final class Scanner: @unchecked Sendable {
        struct Message: Codable, Equatable {
            var time: Date
            var model: String
            var cost: Double
        }

        struct FileState: Codable, Equatable {
            /// Read up to here: the end of the last complete line.
            var offset: UInt64 = 0
            var project: String?
            /// By API message ID: Claude writes a message over several lines
            /// that repeat its usage, the last one counts.
            var messages: [String: Message] = [:]
        }

        private struct Cache: Codable {
            var version = 1
            var files: [String: FileState] = [:]
        }

        private let projects: URL
        private let cacheURL: URL?
        private let lock = NSLock()
        private var files: [String: FileState]?
        private var records: [AgentCostRecord]?
        private var lastSave = Date.distantPast

        init(projects: URL, cache: URL?) {
            self.projects = projects
            self.cacheURL = cache
        }

        func unload() {
            lock.withLock {
                files = nil
                records = nil
            }
        }

        /// Every response of the last `retentionDays` days, each message once
        /// even when a resumed or forked session repeats it in another file.
        func scan(now: Date) -> [AgentCostRecord] {
            lock.withLock {
                var files = self.files ?? loadCache()
                let cutoff = now.addingTimeInterval(-Double(AgentCostLedger.retentionDays) * 86_400)
                var changed = self.files == nil
                var seen = Set<String>()
                for (path, size, modified) in transcripts() where modified >= cutoff {
                    seen.insert(path)
                    var state = files[path] ?? FileState()
                    if size < state.offset { state = FileState() }  // rewritten
                    guard size > state.offset else { continue }
                    Self.read(path, into: &state, size: size)
                    files[path] = state
                    changed = true
                }
                for path in files.keys where !seen.contains(path) {
                    files[path] = nil
                    changed = true
                }
                self.files = files
                if changed || records == nil { records = Self.records(files) }
                if changed, now.timeIntervalSince(lastSave) > 60 || lastSave == .distantPast {
                    saveCache(files)
                    lastSave = now
                }
                return (records ?? []).filter { $0.time >= cutoff }
            }
        }

        /// `(path, size, modified)` of every `.jsonl` below `projects`.
        private func transcripts() -> [(String, UInt64, Date)] {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard
                let walker = FileManager.default.enumerator(
                    at: projects, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { return [] }
            var result: [(String, UInt64, Date)] = []
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                    let size = values.fileSize, let modified = values.contentModificationDate
                else { continue }
                result.append((url.path, UInt64(size), modified))
            }
            return result
        }

        private static let assistantTag = Data("\"type\":\"assistant\"".utf8)

        /// Reads the complete lines appended to `path` since `state.offset`.
        static func read(_ path: String, into state: inout FileState, size: UInt64) {
            var pending = Data()
            var local = state
            let end = AgentTimelineStore.read(path, from: state.offset, to: size) { chunk in
                pending.append(chunk)
                let used = assistantLines(in: pending) { read($0, into: &local) }
                pending = used < pending.count ? Data(pending[(pending.startIndex + used)...]) : Data()
            }
            local.offset = end - UInt64(pending.count)
            state = local
        }

        /// Calls `body` with each complete line of `data` that holds an assistant
        /// message; returns the bytes read, up to the last newline. Uses
        /// `memchr`/`memmem`: a first scan reads gigabytes.
        static func assistantLines(in data: Data, _ body: (Data) -> Void) -> Int {
            data.withUnsafeBytes { raw in
                assistantTag.withUnsafeBytes { tag in
                    guard let base = raw.baseAddress, let tagBase = tag.baseAddress else { return 0 }
                    var start = 0
                    while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                        let end = base.distance(to: UnsafeRawPointer(newline))
                        if memmem(base + start, end - start, tagBase, tag.count) != nil {
                            body(Data(bytes: base + start, count: end - start))
                        }
                        start = end + 1
                    }
                    return start
                }
            }
        }

        static func read(_ line: Data, into state: inout FileState) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any], let id = message["id"] as? String,
                let usage = (message["usage"] as? [String: Any]).map(AgentTimeline.Parser.usage),
                let model = message["model"] as? String, !model.hasPrefix("<"),
                let time = (object["timestamp"] as? String).flatMap(AgentTimeline.Parser.date)
            else { return }
            if state.project == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { state.project = cwd }
            state.messages[id] = Message(
                time: time, model: model, cost: AgentTimeline.estimatedCost(of: usage, model: model))
        }

        /// Flattens the files to one record per message ID; a repeated ID counts
        /// in the first file by path.
        static func records(_ files: [String: FileState]) -> [AgentCostRecord] {
            var seen = Set<String>()
            var records: [AgentCostRecord] = []
            for path in files.keys.sorted() {
                guard let state = files[path] else { continue }
                let (session, subagent) = Self.session(of: path)
                for (id, message) in state.messages where seen.insert(id).inserted {
                    records.append(
                        AgentCostRecord(
                            time: message.time, model: message.model, project: state.project ?? "",
                            session: session, subagent: subagent, cost: message.cost))
                }
            }
            return records
        }

        /// `…/<session>.jsonl` or `…/<session>/subagents/<agent>.jsonl`.
        static func session(of path: String) -> (id: String, subagent: Bool) {
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent()
            if folder.lastPathComponent == "subagents" {
                return (folder.deletingLastPathComponent().lastPathComponent, true)
            }
            return (url.deletingPathExtension().lastPathComponent, false)
        }

        private func loadCache() -> [String: FileState] {
            guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
                let cache = try? PropertyListDecoder().decode(Cache.self, from: data), cache.version == Cache().version
            else { return [:] }
            return cache.files
        }

        private func saveCache(_ files: [String: FileState]) {
            guard let cacheURL else { return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(Cache(files: files)) else { return }
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
