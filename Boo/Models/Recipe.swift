import Foundation

/// A workspace layout saved as `~/.boo/recipes/<name>.json`: a folder plus a
/// tree of splits whose leaves are panes of terminal tabs.
///
/// ```json
/// { "name": "dev", "folder": "~/code/app",
///   "layout": { "split": "right", "ratio": 0.6,
///     "a": { "tabs": [{ "command": "pnpm dev" }] },
///     "b": { "tabs": [{ "cwd": "./api", "env": { "PORT": "4000" } }] } } }
/// ```
struct Recipe: Codable, Equatable {
    var name: String?
    var folder: String
    var layout: Node

    indirect enum Node: Equatable {
        /// One pane. An empty list opens a single plain tab.
        case tabs([Tab])
        /// `a` is left of (`right`) or above (`down`) `b`; `ratio` is `a`'s share.
        case split(Direction, ratio: Double, a: Node, b: Node)
    }

    enum Direction: String, Codable {
        case right, down
    }

    struct Tab: Codable, Equatable {
        /// Typed into the shell when it starts.
        var command: String?
        /// Absolute, `~/…`, or relative to the recipe's folder.
        var cwd: String?
        var env: [String: String]?
        /// Written by "Save as Recipe": what the tab ran last. Never run;
        /// copy it into `command` to run it.
        var lastCommand: String?

        init(command: String? = nil, cwd: String? = nil, env: [String: String]? = nil, lastCommand: String? = nil) {
            self.command = command
            self.cwd = cwd
            self.env = env
            self.lastCommand = lastCommand
        }
    }
}

extension Recipe.Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case tabs, split, ratio, a, b
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.split) {
            let raw = try c.decode(String.self, forKey: .split)
            guard let direction = Recipe.Direction(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .split, in: c, debugDescription: "split must be \"right\" or \"down\", not \"\(raw)\"")
            }
            let ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            self = .split(
                direction, ratio: min(max(ratio, 0.1), 0.9),
                a: try c.decode(Recipe.Node.self, forKey: .a), b: try c.decode(Recipe.Node.self, forKey: .b))
        } else {
            self = .tabs(try c.decodeIfPresent([Recipe.Tab].self, forKey: .tabs) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tabs(let tabs):
            try c.encode(tabs, forKey: .tabs)
        case .split(let direction, let ratio, let a, let b):
            try c.encode(direction, forKey: .split)
            try c.encode((ratio * 100).rounded() / 100, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

// MARK: - Running

/// A recipe resolved against the file system, ready to become a workspace.
struct RecipePlan {
    struct Tab: Equatable {
        let cwd: String
        let launch: LaunchSpec?
    }

    let folder: String
    let tree: SplitTree
    /// Tabs of each leaf in `tree`.
    let panes: [UUID: [Tab]]
    /// The first leaf, which gets focus.
    let firstPaneID: UUID
}

extension Recipe {
    /// Resolves the folder and every tab's cwd. Throws when the folder is not
    /// a directory; nothing should open then.
    func plan(fileManager: FileManager = .default) throws -> RecipePlan {
        let folder = Self.expand(self.folder, relativeTo: nil)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            throw RecipeError.missingFolder(folder)
        }
        var panes: [UUID: [RecipePlan.Tab]] = [:]
        var firstPaneID: UUID?
        func build(_ node: Node) -> SplitTree {
            switch node {
            case .tabs(let tabs):
                let id = UUID()
                if firstPaneID == nil { firstPaneID = id }
                panes[id] = (tabs.isEmpty ? [Tab()] : tabs).map { tab in
                    let command = tab.command.flatMap { $0.isEmpty ? nil : $0 }
                    let env = tab.env ?? [:]
                    return RecipePlan.Tab(
                        cwd: tab.cwd.map { Self.expand($0, relativeTo: folder) } ?? folder,
                        launch: command == nil && env.isEmpty ? nil : LaunchSpec(command: command, env: env))
                }
                return .leaf(id: id)
            case .split(let direction, let ratio, let a, let b):
                return .split(
                    direction: direction == .right ? .horizontal : .vertical, first: build(a), second: build(b),
                    ratio: CGFloat(ratio))
            }
        }
        let tree = build(layout)
        return RecipePlan(folder: folder, tree: tree, panes: panes, firstPaneID: firstPaneID!)
    }

    /// `~` expands to home; a relative path is resolved against `base`.
    static func expand(_ path: String, relativeTo base: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || base == nil { return (expanded as NSString).standardizingPath }
        return ((base! as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

// MARK: - Saving

extension Recipe {
    /// A recipe reproducing `workspace`'s layout and terminal cwds. Other tab
    /// kinds are skipped. Commands stay empty: `lastCommands` (by tab ID) only
    /// fills `lastCommand`.
    init(workspace: Workspace, name: String?, lastCommands: [UUID: String] = [:]) {
        let folder = workspace.folderPath
        func node(_ tree: SplitTree) -> Node {
            switch tree {
            case .leaf(let id):
                let tabs = (workspace.pane(for: id)?.tabs ?? []).filter { $0.contentType == .terminal }.map { tab in
                    Tab(
                        cwd: Self.relative(tab.workingDirectory, to: folder),
                        lastCommand: lastCommands[tab.id].flatMap { $0.isEmpty ? nil : $0 })
                }
                return .tabs(tabs)
            case .split(let direction, let first, let second, let ratio):
                return .split(
                    direction == .horizontal ? .right : .down, ratio: Double(ratio), a: node(first), b: node(second))
            }
        }
        self.init(
            name: name, folder: (folder as NSString).abbreviatingWithTildeInPath, layout: node(workspace.splitTree))
    }

    /// nil for the folder itself, `./sub` inside it, else the path with `~`.
    static func relative(_ path: String, to folder: String) -> String? {
        let path = expand(path, relativeTo: nil)
        let folder = expand(folder, relativeTo: nil)
        if path == folder { return nil }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        if path.hasPrefix(prefix) { return "./" + path.dropFirst(prefix.count) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

enum RecipeError: LocalizedError, Equatable {
    case invalid(path: String, reason: String)
    case missingFolder(String)
    case notFound(String, available: [String])

    var errorDescription: String? {
        switch self {
        case .invalid(let path, let reason):
            return "\(abbreviatePath(path)) is not a valid recipe: \(reason)"
        case .missingFolder(let folder):
            return "The recipe's folder \(abbreviatePath(folder)) does not exist."
        case .notFound(let name, let available):
            let list =
                available.isEmpty
                ? "There are no recipes in ~/.boo/recipes." : "Recipes: \(available.joined(separator: ", "))."
            return "No recipe named \"\(name)\". \(list)"
        }
    }
}
