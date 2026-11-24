import Foundation

/// Deleting a task worktree safely: discard deletes only what the user saw
/// when they approved it, keeps a restorable copy, and cleanup after a merge
/// never forces.
extension AgentWorktree {
    /// The worktree state a discard was approved for.
    struct Snapshot: Equatable {
        /// Commit checked out in the worktree.
        let head: String?
        /// Tree of the whole working directory (tracked and untracked, not
        /// ignored); equal trees mean equal uncommitted work.
        let tree: String?
        /// Fallback fingerprint when the tree could not be written.
        let statusDigest: String?
    }

    /// The worktree changed after the user approved deleting it.
    struct Changed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Ref namespace for discarded tasks; `git branch <name> <ref>` restores one.
    static let trashPrefix = "refs/boo/trash/"
    /// Discarded tasks older than this are dropped from the trash.
    static let trashMaxAge: TimeInterval = 14 * 24 * 3600

    static func snapshot(of info: Info) -> Snapshot {
        let head = try? git(["rev-parse", "-q", "--verify", "HEAD"], in: info.path)
        let status = try? git(["status", "--porcelain", "-uall"], in: info.path)
        return Snapshot(
            head: head, tree: workingTree(of: info.path, head: head), statusDigest: status.map(RuleSet.hash))
    }

    /// Writes the working directory as a tree object through a scratch index,
    /// so the real index and the files stay untouched.
    static func workingTree(of path: String, head: String?) -> String? {
        let index = (NSTemporaryDirectory() as NSString).appendingPathComponent("boo-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: index) }
        let env = ["GIT_INDEX_FILE": index]
        do {
            if head != nil { try git(["read-tree", "HEAD"], in: path, environment: env) }
            try git(["add", "-A", "--", "."], in: path, environment: env)
            return try git(["write-tree"], in: path, environment: env)
        } catch {
            return nil
        }
    }

    /// What changed between the approved state and now, e.g. "2 new commits";
    /// nil when nothing did.
    static func changes(from approved: Snapshot, to current: Snapshot, in info: Info) -> String? {
        guard approved != current else { return nil }
        guard approved.head == current.head else {
            guard let old = approved.head, let new = current.head else { return "its HEAD changed" }
            let isAncestor = (try? git(["merge-base", "--is-ancestor", old, new], in: info.path)) != nil
            guard isAncestor, let count = try? git(["rev-list", "--count", "\(old)..\(new)"], in: info.path) else {
                return "its branch moved (rebased or reset)"
            }
            let n = Int(count) ?? 0
            return "\(n) new commit\(n == 1 ? "" : "s")"
        }
        return "new uncommitted changes"
    }

    /// Deletes the worktree and branch, but only when nothing changed since
    /// `approved` (nil: no check). Saves the work first under
    /// `refs/boo/trash/<name>` and returns the command that restores it.
    @discardableResult
    static func discard(_ info: Info, approved: Snapshot?, now date: Date = Date()) throws -> String? {
        let current = snapshot(of: info)
        if let approved, let change = changes(from: approved, to: current, in: info) {
            throw Changed(message: "The task changed since you approved discarding it: \(change). Nothing was deleted.")
        }
        let restore = trash(info, snapshot: current)
        try remove(info, deleteBranch: true)
        pruneTrash(in: info.mainRoot, now: date)
        return restore
    }

    /// Commits the working tree on top of HEAD and points a trash ref at it.
    /// nil when the backup failed; the discard goes on without it.
    static func trash(_ info: Info, snapshot: Snapshot) -> String? {
        guard let tree = snapshot.tree else { return nil }
        let base = info.branch.map { String($0.dropFirst($0.hasPrefix(branchPrefix) ? branchPrefix.count : 0)) }
        let stem = slug(base ?? (info.path as NSString).lastPathComponent)
        var name = stem
        for attempt in 2...100 {
            guard (try? git(["rev-parse", "-q", "--verify", trashPrefix + name], in: info.mainRoot)) != nil else {
                break
            }
            name = "\(stem)-\(attempt)"
        }
        let restoreBranch = info.branch ?? branchPrefix + name
        let message = "boo: discarded \(name)\n\nRestore: git branch \(restoreBranch) \(trashPrefix)\(name)"
        var args = ["-c", "user.name=Boo", "-c", "user.email=boo@localhost", "commit-tree", tree, "-m", message]
        if let head = snapshot.head { args += ["-p", head] }
        guard let commit = try? git(args, in: info.mainRoot),
            (try? git(["update-ref", trashPrefix + name, commit], in: info.mainRoot)) != nil
        else { return nil }
        return "git branch \(restoreBranch) \(trashPrefix)\(name)"
    }

    /// Drops trash refs older than `trashMaxAge`.
    static func pruneTrash(in repo: String, now: Date = Date()) {
        guard
            let list = try? git(
                ["for-each-ref", "--format=%(committerdate:unix) %(refname)", trashPrefix], in: repo)
        else { return }
        let cutoff = now.timeIntervalSince1970 - trashMaxAge
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = TimeInterval(parts[0]), time < cutoff else { continue }
            _ = try? git(["update-ref", "-d", parts[1]], in: repo)
        }
    }

    /// Cleanup after a merge, without force: keeps the worktree when it has
    /// uncommitted work or commits the target lacks (the agent kept working),
    /// and the branch when it is not fully merged. Returns what it kept, nil
    /// when everything was removed.
    static func removeMerged(_ info: Info) -> String? {
        let path = (info.path as NSString).abbreviatingWithTildeInPath
        guard let branch = info.branch else { return "kept \(path): it is not on a branch" }
        func isMerged() -> Bool {
            (try? git(["merge-base", "--is-ancestor", branch, "HEAD"], in: info.mainRoot)) != nil
        }
        guard isMerged() else { return "kept \(path): \(branch) has commits that are not merged" }
        do {
            // Without --force git refuses a worktree with uncommitted or untracked files.
            try git(["worktree", "remove", info.path], in: info.mainRoot)
        } catch {
            return "kept \(path): \(error.localizedDescription)"
        }
        removeEmptyParent(of: info.path)
        // A commit can land between the check and the removal.
        guard isMerged() else { return "kept branch \(branch): it has commits that are not merged" }
        do {
            try git(["branch", "-D", branch], in: info.mainRoot)
        } catch {
            return "kept branch \(branch): \(error.localizedDescription)"
        }
        return nil
    }

    /// The repo's folder under the worktree root stays behind once its last task is gone.
    static func removeEmptyParent(of path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        if (try? FileManager.default.contentsOfDirectory(atPath: parent))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: parent)
        }
    }

    // MARK: - Socket encoding

    /// Keys a gate card pins the approved state under.
    static let approvedHeadKey = "approved_head"
    static let approvedTreeKey = "approved_tree"
    static let approvedStatusKey = "approved_status"

    static func encode(_ snapshot: Snapshot) -> [String: String] {
        [
            approvedHeadKey: snapshot.head ?? "", approvedTreeKey: snapshot.tree ?? "",
            approvedStatusKey: snapshot.statusDigest ?? ""
        ]
    }

    /// nil when the message carries no approved state.
    static func decodeSnapshot(_ json: [String: Any]) -> Snapshot? {
        guard let head = json[approvedHeadKey] as? String else { return nil }
        func value(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Snapshot(
            head: head.isEmpty ? nil : head, tree: value(approvedTreeKey), statusDigest: value(approvedStatusKey))
    }
}
