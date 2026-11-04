import Foundation

/// One line per task worktree for the crew rows: how much work is on its
/// branch and whether it merges, so a task can be judged without opening
/// Review. Git runs off the main thread; rows read the last answer and a
/// changed answer reruns the sidebar.
@MainActor
final class AgentTaskStatus {
    static let shared = AgentTaskStatus()

    struct Summary: Equatable {
        enum Tone: Equatable { case neutral, ready, blocked }
        let text: String
        let tone: Tone
        /// The task's branch, for the row's help text.
        let branch: String?
    }

    /// An answer is asked again after this long, or when the agent changes state.
    static let ttl: TimeInterval = 20

    private struct Entry {
        var summary: Summary?
        var stamp: String
        var at: Date
    }
    private var entries: [String: Entry] = [:]
    private var running: Set<String> = []
    private var observer: NSObjectProtocol?

    private init() {
        // A merge or discard changes the answer at once.
        observer = NotificationCenter.default.addObserver(forName: .agentWorktreesChanged, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.entries.removeAll() }
        }
    }

    /// The last summary for the worktree at `path`. Starts a refresh when there is
    /// none yet, it is older than `ttl`, or `stamp` (the agent's state) changed.
    func summary(for path: String, stamp: String) -> Summary? {
        let entry = entries[path]
        if entry == nil || entry?.stamp != stamp || Date().timeIntervalSince(entry?.at ?? .distantPast) > Self.ttl {
            refresh(path, stamp: stamp)
        }
        return entry?.summary
    }

    private func refresh(_ path: String, stamp: String) {
        guard running.insert(path).inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            let summary = AgentWorktree.info(for: path).map { info in
                Self.summary(check: AgentWorktree.mergeCheck(of: info), files: Self.changedFiles(info), info: info)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running.remove(path)
                    let changed = self.entries[path]?.summary != summary
                    self.entries[path] = Entry(summary: summary, stamp: stamp, at: Date())
                    if changed { NotificationCenter.default.post(name: .agentCrewChanged, object: self) }
                }
            }
        }
    }

    /// Files the branch changed since it left the target branch.
    nonisolated private static func changedFiles(_ info: AgentWorktree.Info) -> Int {
        guard let branch = info.branch,
            let target = try? AgentWorktree.git(["symbolic-ref", "--short", "-q", "HEAD"], in: info.mainRoot),
            !target.isEmpty,
            let names = try? AgentWorktree.git(["diff", "--name-only", "\(target)...\(branch)"], in: info.mainRoot)
        else { return 0 }
        return names.split(separator: "\n").count
    }

    /// "2 commits · 5 files · merges cleanly", or what stops the merge.
    nonisolated static func summary(
        check: AgentWorktree.MergeCheck, files: Int, info: AgentWorktree.Info
    ) -> Summary {
        let target = check.status.target ?? "the target"
        var parts: [String] = []
        let ahead = check.status.ahead
        if ahead > 0 { parts.append(ahead == 1 ? "1 commit" : "\(ahead) commits") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        let tone: Summary.Tone
        switch check.blocker {
        case nil:
            parts.append("merges into \(target)")
            tone = .ready
        case "conflicts":
            let count = check.conflicts?.count ?? 0
            parts.append(count == 1 ? "1 conflict with \(target)" : "\(count) conflicts with \(target)")
            tone = .blocked
        case "dirty":
            parts.append("uncommitted changes")
            tone = .neutral
        case "target_dirty":
            parts.append("\(target) checkout has changes")
            tone = .blocked
        case "nothing_to_merge":
            parts.append("no commits yet")
            tone = .neutral
        default:  // no_target
            tone = .neutral
        }
        return Summary(text: parts.joined(separator: " · "), tone: tone, branch: info.branch)
    }
}
