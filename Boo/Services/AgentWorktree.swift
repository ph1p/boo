import Foundation

/// Git worktrees that give each agent task its own checkout and branch, so
/// several agents can work on one repository without touching each other.
///
/// Stateless: a workspace is an agent task when its folder is a linked
/// worktree, and everything else (main checkout, branch, target branch) is
/// read back from git when needed. All functions block; call off the main thread.
enum AgentWorktree {
    struct Info: Equatable {
        /// The linked worktree's top-level directory.
        let path: String
        /// The main checkout the worktree belongs to.
        let mainRoot: String
        /// Branch checked out in the worktree; nil when detached.
        let branch: String?
    }

    struct Status: Equatable {
        /// Uncommitted changes (tracked or untracked) in the worktree.
        let isDirty: Bool
        /// Commits on the worktree branch that the target branch lacks.
        let ahead: Int
        /// Branch checked out in the main checkout: where a merge lands.
        let target: String?
    }

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Prefix for task branches: `boo/<slug>`.
    static let branchPrefix = "boo/"

    /// `~/.boo/worktrees`: task checkouts live outside the repository so they
    /// never show up as untracked files in it.
    static var defaultRoot: String { (BooPaths.configDir as NSString).appendingPathComponent("worktrees") }

    // MARK: - Queries

    /// Top-level directory of the repository containing `path`.
    static func repoRoot(of path: String) -> String? {
        let out = try? git(["rev-parse", "--show-toplevel"], in: path)
        return out.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Main checkout of the repository containing `path`, also when `path` is
    /// inside a linked worktree: where task branches and worktrees hang off.
    static func mainRoot(of path: String) -> String? {
        info(for: path)?.mainRoot ?? repoRoot(of: path).map(standardized)
    }

    /// Worktree details when `path` is inside a linked worktree; nil for a main
    /// checkout or a folder outside git.
    static func info(for path: String) -> Info? {
        guard
            let out = try? git(
                ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: path)
        else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        let (top, gitDir, commonDir) = (standardized(lines[0]), standardized(lines[1]), standardized(lines[2]))
        guard gitDir != commonDir else { return nil }
        let mainRoot = (commonDir as NSString).deletingLastPathComponent
        let branch = try? git(["symbolic-ref", "--short", "-q", "HEAD"], in: top)
        return Info(path: top, mainRoot: mainRoot, branch: branch.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Cheap check for menus: linked worktrees have a `.git` file, not a directory.
    static func looksLikeWorktree(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) && !isDir.boolValue
    }

    static func status(of info: Info) -> Status {
        let dirty = (try? git(["status", "--porcelain"], in: info.path)).map { !$0.isEmpty } ?? false
        let target = (try? git(["symbolic-ref", "--short", "-q", "HEAD"], in: info.mainRoot)).flatMap {
            $0.isEmpty ? nil : $0
        }
        var ahead = 0
        if let branch = info.branch, let target,
            let count = try? git(["rev-list", "--count", "\(target)..\(branch)"], in: info.mainRoot)
        {
            ahead = Int(count) ?? 0
        }
        return Status(isDirty: dirty, ahead: ahead, target: target)
    }

    /// Everything that decides whether a task can merge, for `task_status`.
    struct MergeCheck: Equatable {
        let status: Status
        /// Commits on the target branch that the worktree branch lacks.
        let behind: Int
        /// Uncommitted changes to tracked files in the main checkout.
        let targetDirty: Bool
        /// Files a merge would conflict on; nil when git could not tell.
        let conflicts: [String]?

        /// Why the task cannot merge now, nil when it can.
        var blocker: String? {
            if status.target == nil { return "no_target" }
            if status.isDirty { return "dirty" }
            if targetDirty { return "target_dirty" }
            if let conflicts, !conflicts.isEmpty { return "conflicts" }
            if status.ahead == 0 { return "nothing_to_merge" }
            return nil
        }
    }

    static func mergeCheck(of info: Info) -> MergeCheck {
        let status = status(of: info)
        var behind = 0
        var conflicts: [String]?
        if let branch = info.branch, let target = status.target {
            if let count = try? git(["rev-list", "--count", "\(branch)..\(target)"], in: info.mainRoot) {
                behind = Int(count) ?? 0
            }
            conflicts = mergeConflicts(of: branch, into: target, in: info.mainRoot)
        }
        return MergeCheck(
            status: status, behind: behind, targetDirty: isDirtyCheckout(info.mainRoot), conflicts: conflicts)
    }

    /// Tracked files with uncommitted changes. Untracked files don't count: git
    /// itself refuses a merge that would overwrite one.
    static func isDirtyCheckout(_ path: String) -> Bool {
        (try? git(["status", "--porcelain", "--untracked-files=no"], in: path)).map { !$0.isEmpty } ?? false
    }

    /// Files that conflict when `branch` merges into `target`, without touching
    /// any checkout (`git merge-tree --write-tree`, git 2.38+). nil when git failed.
    static func mergeConflicts(of branch: String, into target: String, in repo: String) -> [String]? {
        guard
            let result = run(["merge-tree", "--write-tree", "--name-only", "--no-messages", target, branch], in: repo),
            result.status == 0 || result.status == 1
        else { return nil }
        // First line is the tree id; conflicted paths follow.
        return result.status == 0
            ? [] : result.stdout.split(separator: "\n").dropFirst().map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Changes

    /// Creates branch `boo/<slug>` from `base` (default: the main checkout's
    /// HEAD), checked out in `<root>/<repo name>/<slug>`. Picks a free suffix
    /// when either is taken. `repo` may be a worktree: tasks always hang off the
    /// main checkout.
    static func create(repo: String, name: String, base: String? = nil, root: String = defaultRoot) throws -> Info {
        guard let repoRoot = mainRoot(of: repo) else {
            throw GitError(message: "\((repo as NSString).abbreviatingWithTildeInPath) is not a git repository.")
        }
        let start = base.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        let stem = slug(name)
        let parent = (root as NSString).appendingPathComponent((repoRoot as NSString).lastPathComponent)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        for attempt in 1...50 {
            let candidate = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let path = (parent as NSString).appendingPathComponent(candidate)
            let branch = branchPrefix + candidate
            guard !FileManager.default.fileExists(atPath: path), !branchExists(branch, in: repoRoot) else { continue }
            try git(["worktree", "add", "-b", branch, path, start], in: repoRoot)
            return Info(path: path, mainRoot: repoRoot, branch: branch)
        }
        throw GitError(message: "No free worktree name for \"\(stem)\".")
    }

    /// Merges the worktree branch into whatever the main checkout has checked out.
    /// Refuses with uncommitted changes in the worktree or the main checkout
    /// (never stashes); a conflicting merge is aborted so the main checkout is
    /// left as it was.
    static func merge(_ info: Info) throws {
        guard let branch = info.branch else { throw GitError(message: "The worktree is not on a branch.") }
        if status(of: info).isDirty {
            throw GitError(message: "The worktree has uncommitted changes. Commit or discard them first.")
        }
        if isDirtyCheckout(info.mainRoot) {
            throw GitError(
                message:
                    "\((info.mainRoot as NSString).abbreviatingWithTildeInPath) has uncommitted changes. Commit or stash them first."
            )
        }
        do {
            try git(["merge", "--no-ff", "--no-edit", branch], in: info.mainRoot)
        } catch {
            _ = try? git(["merge", "--abort"], in: info.mainRoot)
            throw error
        }
    }

    /// Deletes the checkout and, when given, its branch.
    static func remove(_ info: Info, deleteBranch: Bool) throws {
        try git(["worktree", "remove", "--force", info.path], in: info.mainRoot)
        if deleteBranch, let branch = info.branch {
            try git(["branch", "-D", branch], in: info.mainRoot)
        }
    }

    // MARK: - Helpers

    /// "Fix the login bug!" → "fix-the-login-bug". Never empty.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "task" : out
    }

    private static func branchExists(_ branch: String, in repo: String) -> Bool {
        (try? git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: repo)) != nil
    }

    /// realpath(3): unlike `resolvingSymlinksInPath` it keeps `/private`, matching git's own paths.
    private static func standardized(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs git and returns trimmed stdout; throws with git's message on failure.
    @discardableResult
    static func git(_ args: [String], in directory: String) throws -> String {
        guard let result = run(args, in: directory) else {
            throw GitError(message: "git \(args.first ?? "") timed out.")
        }
        guard result.status == 0 else {
            let message = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw GitError(message: message ?? "git \(args.first ?? "") failed.")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git, any exit status; nil when it timed out or could not start.
    private static func run(_ args: [String], in directory: String) -> RemoteExplorer.CommandResult? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        task.environment = env
        return RemoteExplorer.runProcessCapturing(task, timeout: 30)
    }
}
