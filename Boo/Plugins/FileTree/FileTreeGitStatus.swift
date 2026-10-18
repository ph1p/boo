import Foundation

/// Per-path git state shown as file tree decorations. Declared weakest first: the
/// raw value is the rank a folder uses to roll up the state of its descendants.
enum FileGitStatus: Int, Comparable, Sendable {
    case ignored, untracked, renamed, added, deleted, modified, conflicted

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// One-letter badge, VS Code style.
    var badge: String {
        switch self {
        case .conflicted: return "!"
        case .modified: return "M"
        case .deleted: return "D"
        case .added: return "A"
        case .renamed: return "R"
        case .untracked: return "U"
        case .ignored: return ""
        }
    }

    /// Map a porcelain v1 `XY` pair.
    init?(x: Character, y: Character) {
        switch (x, y) {
        case ("?", "?"): self = .untracked
        case ("!", "!"): self = .ignored
        case ("U", _), (_, "U"), ("D", "D"), ("A", "A"): self = .conflicted
        case ("R", _), ("C", _): self = .renamed
        case ("A", _): self = .added
        case ("D", _), (_, "D"): self = .deleted
        case (" ", " "): return nil
        default: self = .modified
        }
    }
}

/// Snapshot of `git status` for a repo, keyed by node-form absolute paths.
struct FileTreeGitStatus: Equatable, Sendable {
    /// Repo root in the same path form as the tree's nodes (see `load`).
    let repoRoot: String
    /// Status reported for an exact path. Directory entries (`?? dir/`, `!! dir/`)
    /// are stored without their trailing slash and inherited by everything below.
    private(set) var entries: [String: FileGitStatus] = [:]
    /// Strongest non-ignored status found below each ancestor folder.
    private(set) var folderRollup: [String: FileGitStatus] = [:]

    /// Parse `git status --porcelain=v1 -z --ignored=matching` output.
    init(repoRoot: String, porcelainZ output: String) {
        self.repoRoot = repoRoot
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard field.count >= 4 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            // Renames/copies carry the original path in the next NUL field.
            if x == "R" || x == "C" { i += 1 }
            guard let status = FileGitStatus(x: x, y: y) else { continue }
            var rel = String(field.dropFirst(3))
            if rel.hasSuffix("/") { rel.removeLast() }
            record(status, at: (repoRoot as NSString).appendingPathComponent(rel))
        }
    }

    private mutating func record(_ status: FileGitStatus, at path: String) {
        entries[path] = status
        guard status != .ignored else { return }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count >= repoRoot.count {
            if let existing = folderRollup[dir], existing >= status { break }
            folderRollup[dir] = status
            if dir == repoRoot { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// Status for a node: its own entry, else one inherited from an untracked or
    /// ignored ancestor folder, else (for folders) the rollup of its descendants.
    func status(for path: String, isDirectory: Bool) -> FileGitStatus? {
        if let own = entries[path] { return own }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > repoRoot.count {
            if let inherited = entries[dir], inherited == .untracked || inherited == .ignored {
                return inherited
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return isDirectory ? folderRollup[path] : nil
    }

    /// Run git for the tree rooted at `rootPath`. Returns nil outside a repo.
    ///
    /// `git rev-parse --show-toplevel` answers with a *resolved* path (`/private/var/…`
    /// for a cwd of `/var/…`), which would never match the tree's node paths. Instead,
    /// strip `--show-prefix` (rootPath's location inside the repo) off rootPath itself
    /// so the repo root keeps the tree's path form.
    static func load(rootPath: String) -> FileTreeGitStatus? {
        guard let prefix = GitPlugin.gitOutput(["-C", rootPath, "rev-parse", "--show-prefix"]) else {
            return nil
        }
        var repoRoot = rootPath
        let depth = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").count
        for _ in 0..<depth { repoRoot = (repoRoot as NSString).deletingLastPathComponent }

        guard
            // `-- .` scopes the walk to the tree root; porcelain paths stay repo-relative.
            // `--ignored=matching` reports ignored folders without walking into them
            // (plain `--ignored` descends node_modules/.build: ~50x slower).
            let output = GitPlugin.gitOutput(
                [
                    "-C", rootPath, "--no-optional-locks", "status", "--porcelain=v1", "-z", "--ignored=matching",
                    "--", "."
                ]
            )
        else { return nil }
        return FileTreeGitStatus(repoRoot: repoRoot, porcelainZ: output)
    }
}
