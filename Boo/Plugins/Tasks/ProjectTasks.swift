import Foundation

/// A runnable project task: a package.json script, make target, just recipe,
/// or a standard cargo / SwiftPM command.
struct ProjectTask: Identifiable, Hashable, Sendable {
    /// The tool that runs it ("pnpm", "make", "just", "cargo", "swift"…).
    let tool: String
    let name: String
    let command: String
    /// The script body or doc comment, shown under the name.
    var detail: String = ""

    var id: String { "\(tool):\(name)" }
}

/// The tasks found in one folder.
struct ProjectTaskGroup: Identifiable, Equatable, Sendable {
    let root: String
    let tasks: [ProjectTask]

    var id: String { root }
}

/// Finds the tasks of the project around a working directory.
enum ProjectTaskScanner {
    static let packageJSON = "package.json"
    static let makefiles = ["GNUmakefile", "makefile", "Makefile"]
    static let justfiles = ["justfile", "Justfile", ".justfile"]
    static let cargoToml = "Cargo.toml"
    static let packageSwift = "Package.swift"

    /// The nearest folder with tasks at or above `cwd`, plus the repository
    /// root when that is a different folder with tasks of its own. Stops at the
    /// repository root, or else at the home folder.
    static func groups(cwd: String, repoRoot: String? = nil, home: String = NSHomeDirectory()) -> [ProjectTaskGroup] {
        guard !cwd.isEmpty else { return [] }
        let start = standardized(cwd)
        let stop = repoRoot.map(standardized)
        var groups: [ProjectTaskGroup] = []
        var dir = start
        while true {
            let tasks = tasks(in: dir)
            if !tasks.isEmpty {
                groups.append(ProjectTaskGroup(root: dir, tasks: tasks))
                break
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if dir == stop || dir == standardized(home) || parent == dir || parent.isEmpty { break }
            dir = parent
        }
        if let stop, groups.first?.root != stop, start == stop || start.hasPrefix(stop + "/") {
            let tasks = tasks(in: stop)
            if !tasks.isEmpty { groups.append(ProjectTaskGroup(root: stop, tasks: tasks)) }
        }
        return groups
    }

    /// Every task in one folder, grouped by tool.
    static func tasks(in dir: String, fileManager: FileManager = .default) -> [ProjectTask] {
        func read(_ name: String) -> String? {
            let path = (dir as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path) else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
        }
        var tasks: [ProjectTask] = []
        if let json = read(packageJSON) {
            let manager = packageManager(packageJSON: json, lockfiles: lockfiles.filter { exists($0.key) }.map(\.key))
            tasks += packageScripts(json, manager: manager)
        }
        if let text = makefiles.lazy.compactMap(read).first { tasks += makeTargets(text) }
        if let text = justfiles.lazy.compactMap(read).first { tasks += justRecipes(text) }
        if let toml = read(cargoToml) { tasks += cargoTasks(toml) }
        if let manifest = read(packageSwift) { tasks += swiftTasks(manifest) }
        return tasks
    }

    // MARK: - package.json

    private static let lockfiles: [String: String] = [
        "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "bun.lockb": "bun", "bun.lock": "bun",
        "package-lock.json": "npm"
    ]

    /// The `packageManager` field wins, then the lockfile; npm otherwise.
    static func packageManager(packageJSON: String, lockfiles present: [String]) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(packageJSON.utf8)) as? [String: Any],
            let field = object["packageManager"] as? String,
            let name = field.split(separator: "@").first, ["npm", "pnpm", "yarn", "bun"].contains(String(name))
        {
            return String(name)
        }
        for name in ["pnpm", "bun", "yarn", "npm"] where present.contains(where: { lockfiles[$0] == name }) {
            return name
        }
        return "npm"
    }

    /// Scripts in file order (JSONSerialization loses it, so the keys are
    /// re-ordered by where they appear in the text).
    static func packageScripts(_ json: String, manager: String) -> [ProjectTask] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let scripts = object["scripts"] as? [String: Any]
        else { return [] }
        let scriptsStart = json.range(of: "\"scripts\"")?.upperBound ?? json.startIndex
        func position(_ key: String) -> String.Index {
            json.range(of: "\"\(key)\"", range: scriptsStart..<json.endIndex)?.lowerBound ?? json.endIndex
        }
        return scripts.keys.sorted { position($0) < position($1) }.map { name in
            ProjectTask(
                tool: manager, name: name, command: "\(manager) run \(shellEscape(name))",
                detail: scripts[name] as? String ?? "")
        }
    }

    // MARK: - Makefile

    /// Explicit targets at the start of a line; `## text` after the target is
    /// its description. Skips special (`.PHONY`), pattern (`%`) and variable
    /// (`$(…)`) targets and `:=` assignments.
    static func makeTargets(_ text: String) -> [ProjectTask] {
        var seen = Set<String>()
        var tasks: [ProjectTask] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, !first.isWhitespace, first != "#",
                let colon = line.firstIndex(of: ":")
            else { continue }
            let after = line[line.index(after: colon)...]
            if after.first == "=" { continue }
            let head = line[..<colon]
            if head.contains("=") { continue }
            let description = line.range(of: "##").map {
                line[$0.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            for name in head.split(whereSeparator: \.isWhitespace).map(String.init)
            where !name.hasPrefix(".") && !name.contains("%") && !name.contains("$") && seen.insert(name).inserted {
                tasks.append(
                    ProjectTask(
                        tool: "make", name: name, command: "make \(shellEscape(name))", detail: description ?? ""))
            }
        }
        return tasks
    }

    // MARK: - justfile

    /// Public recipes; a `# comment` right above one is its description.
    /// Skips `_private` recipes, `[private]` ones, settings and assignments.
    static func justRecipes(_ text: String) -> [ProjectTask] {
        let keywords: Set<String> = ["set", "alias", "export", "import", "mod", "if", "else"]
        var tasks: [ProjectTask] = []
        var comment = ""
        var isPrivate = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let first = line.first, !first.isWhitespace else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { comment = "" }
                continue
            }
            if first == "#" {
                comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            if first == "[" {
                if line.contains("private") { isPrivate = true }
                continue
            }
            defer {
                comment = ""
                isPrivate = false
            }
            guard let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].first != "=" else { continue }
            let head = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !head.contains("=") || head.contains(" ") else { continue }
            var parts = head.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { continue }
            var name = parts.removeFirst()
            if name.hasPrefix("@") { name.removeFirst() }
            guard !name.isEmpty, !name.hasPrefix("_"), !keywords.contains(name), !isPrivate,
                name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { continue }
            let params = parts.joined(separator: " ")
            let detail = [comment, params.isEmpty ? "" : "args: \(params)"].filter { !$0.isEmpty }.joined(
                separator: " · ")
            tasks.append(ProjectTask(tool: "just", name: name, command: "just \(name)", detail: detail))
        }
        return tasks
    }

    // MARK: - Cargo / SwiftPM

    static func cargoTasks(_ toml: String) -> [ProjectTask] {
        let hasPackage = toml.contains("[package]")
        let names = hasPackage ? ["build", "test", "run", "check", "clippy"] : ["build", "test", "check", "clippy"]
        return names.map { ProjectTask(tool: "cargo", name: $0, command: "cargo \($0)") }
    }

    static func swiftTasks(_ manifest: String) -> [ProjectTask] {
        let runs = manifest.contains("executableTarget") || manifest.contains(".executable(")
        return (runs ? ["build", "test", "run"] : ["build", "test"]).map {
            ProjectTask(tool: "swift", name: $0, command: "swift \($0)")
        }
    }

    static func standardized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let result = (expanded as NSString).standardizingPath
        return result.isEmpty ? expanded : result
    }
}
