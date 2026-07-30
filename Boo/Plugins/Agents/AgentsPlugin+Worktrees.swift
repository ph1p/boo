import AppKit
import Foundation

// MARK: - Worktree Scanning

extension AgentsPlugin {
    func scanWorktrees(cwd: String?) {
        guard let cwd = cwd else { return }

        withProjectRoot(cwd: cwd) { [weak self] projectRoot in
            guard let self else { return }
            guard self.worktreeScan.shouldScan(root: projectRoot, ttl: Self.scanTTL) else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                let worktrees = Self.detectWorktrees(projectRoot: projectRoot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Skip the rerun when nothing actually changed — this runs on every
                    // focus/cwd cycle. Compare the same key the section's generation
                    // uses, so a branch/commit move still refreshes.
                    let key = { (w: ClaudeWorktree) in
                        "\(w.path)|\(w.branch)|\(w.headCommit ?? "")"
                    }
                    guard self.worktrees.map(key) != worktrees.map(key) else { return }
                    self.worktrees = worktrees
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    /// Enumerate the git worktrees belonging to `projectRoot`.
    ///
    /// Uses `git worktree list --porcelain`, which is authoritative: it finds worktrees
    /// wherever they live, not only under the Claude-specific `.claude/worktrees`
    /// convention, and it reports branch/HEAD correctly for detached heads, packed
    /// refs and relative `gitdir:` pointers — all of which the previous hand-rolled
    /// `.git` file parsing got wrong.
    ///
    /// The entry for the main working tree itself is skipped; only linked worktrees
    /// are returned.
    nonisolated static func detectWorktrees(projectRoot: String) -> [ClaudeWorktree] {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", projectRoot, "--no-optional-locks", "worktree", "list", "--porcelain"]

        // `runProcessCapturing` owns the pipes and drains them incrementally, so a
        // child that outruns the 64KB pipe buffer can't deadlock. A local
        // `worktree list` that needs more than a few seconds is already pathological.
        guard let result = RemoteExplorer.runProcessCapturing(task, timeout: 5),
            result.status == 0
        else { return [] }

        return parseWorktreePorcelain(result.stdout, projectRoot: projectRoot)
    }

    /// Parse `git worktree list --porcelain` output into worktree records.
    ///
    /// Records are separated by blank lines. Each starts with `worktree <path>`, then
    /// carries either `branch refs/heads/<name>`, or `detached`, plus a `HEAD <sha>`.
    /// A `bare` record has no working tree and is skipped.
    nonisolated static func parseWorktreePorcelain(_ output: String, projectRoot: String) -> [ClaudeWorktree] {
        let fm = FileManager.default
        var worktrees: [ClaudeWorktree] = []

        var path: String?
        var branch: String?
        var head: String?
        var isBare = false

        func flush() {
            defer {
                path = nil
                branch = nil
                head = nil
                isBare = false
            }
            guard let path, !isBare else { return }
            // The first record is the main working tree; only linked worktrees are listed.
            guard path != projectRoot else { return }

            let name = (path as NSString).lastPathComponent
            let created = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date

            worktrees.append(
                ClaudeWorktree(
                    id: path,
                    path: path,
                    // Detached worktrees have no branch; show the short SHA instead.
                    branch: branch ?? head.map { "detached @ \($0)" } ?? name,
                    headCommit: head,
                    created: created
                ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                // A new record begins; emit whatever preceded it.
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count).prefix(7))
            } else if line == "bare" {
                isBare = true
            }
        }
        flush()

        // Sort by creation date, newest first
        return worktrees.sorted { a, b in
            let aDate = a.created ?? .distantPast
            let bDate = b.created ?? .distantPast
            return aDate > bDate
        }
    }

    func openWorktree(_ worktree: ClaudeWorktree) {
        // Open the worktree directory in a new tab
        actions?.openDirectoryInNewTab?(worktree.path)
    }
}
