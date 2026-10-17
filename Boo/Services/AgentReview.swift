import Foundation

/// Reviewing what an agent changed: everything in a workspace since it branched
/// off (agent task worktrees) or since the last commit (any other repository),
/// committed or not, untracked files included. Comments on lines are composed
/// into one message for the agent.
enum AgentReview {
    struct DiffLine: Equatable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        let oldLine: Int?
        let newLine: Int?
        let text: String
    }

    struct Hunk: Equatable {
        let header: String
        var lines: [DiffLine]
    }

    struct FileDiff: Equatable, Identifiable {
        enum Status: Equatable { case modified, added, deleted, renamed }
        var path: String
        var oldPath: String?
        var status: Status = .modified
        var isBinary = false
        var hunks: [Hunk] = []
        var id: String { path }
        var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    }

    struct Changes: Equatable {
        var files: [FileDiff]
        /// What the diff is against, e.g. "main" or "HEAD".
        var base: String
        /// Agent task branch when the folder is a worktree.
        var branch: String?
    }

    struct Comment: Equatable, Identifiable {
        let id: UUID
        let file: String
        /// New-side line number, or the old one for removed lines.
        let line: Int
        let snippet: String
        var text: String

        init(file: String, line: Int, snippet: String, text: String, id: UUID = UUID()) {
            self.id = id
            self.file = file
            self.line = line
            self.snippet = snippet
            self.text = text
        }
    }

    /// Untracked files larger than this are listed without content.
    static let maxUntrackedBytes = 512 * 1024

    // MARK: - Loading

    /// Blocks; call off the main thread.
    static func changes(in folder: String) throws -> Changes {
        guard let root = AgentWorktree.repoRoot(of: folder) else {
            throw AgentWorktree.GitError(
                message: "\((folder as NSString).abbreviatingWithTildeInPath) is not a git repository.")
        }
        var base = "HEAD"
        var baseLabel = "HEAD"
        let info = AgentWorktree.info(for: root)
        if let info, let target = AgentWorktree.status(of: info).target,
            let mergeBase = try? AgentWorktree.git(["merge-base", target, "HEAD"], in: root), !mergeBase.isEmpty
        {
            base = mergeBase
            baseLabel = target
        }
        // An unborn branch has no HEAD: diff against the empty tree.
        if base == "HEAD", (try? AgentWorktree.git(["rev-parse", "--verify", "-q", "HEAD"], in: root)) == nil {
            base = emptyTree
        }
        let diff = try AgentWorktree.git(
            ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "-M", base], in: root)
        var files = parse(diff)
        let untracked = (try? AgentWorktree.git(["ls-files", "--others", "--exclude-standard", "-z"], in: root)) ?? ""
        for path in untracked.split(separator: "\0").map(String.init).sorted() {
            files.append(untrackedFile(path, root: root))
        }
        return Changes(files: files, base: baseLabel, branch: info?.branch)
    }

    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private static func untrackedFile(_ path: String, root: String) -> FileDiff {
        var file = FileDiff(path: path, status: .added)
        let full = (root as NSString).appendingPathComponent(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
        guard size <= maxUntrackedBytes, let data = FileManager.default.contents(atPath: full),
            !data.contains(0), let text = String(data: data, encoding: .utf8)
        else {
            file.isBinary = true
            return file
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return file }
        let diffLines = lines.enumerated().map { DiffLine(kind: .added, oldLine: nil, newLine: $0 + 1, text: $1) }
        file.hunks = [Hunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: diffLines)]
        return file
    }

    // MARK: - Parsing

    /// Parses `git diff` output (unified, with `diff --git` headers).
    static func parse(_ diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: Hunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                file = FileDiff(path: pathFromDiffHeader(line))
                continue
            }
            guard file != nil else { continue }
            if hunk != nil, let first = line.first, first == " " || first == "+" || first == "-" {
                let text = String(line.dropFirst())
                switch first {
                case "+":
                    hunk?.lines.append(DiffLine(kind: .added, oldLine: nil, newLine: newLine, text: text))
                    newLine += 1
                case "-":
                    hunk?.lines.append(DiffLine(kind: .removed, oldLine: oldLine, newLine: nil, text: text))
                    oldLine += 1
                default:
                    hunk?.lines.append(DiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: text))
                    oldLine += 1
                    newLine += 1
                }
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                (oldLine, newLine) = hunkStarts(line)
                hunk = Hunk(header: line, lines: [])
            } else if line.hasPrefix("new file mode") {
                file?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                file?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                file?.status = .renamed
                file?.oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                file?.path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") {
                file?.isBinary = true
            } else if line.hasPrefix("+++ b/") {
                file?.path = String(line.dropFirst("+++ b/".count))
            } else if line.hasPrefix("--- a/"), file?.status == .deleted {
                file?.path = String(line.dropFirst("--- a/".count))
            }
            // "\ No newline at end of file" and other headers carry nothing to show.
        }
        flushFile()
        return files
    }

    /// `diff --git a/x b/x` → "x". Exact for unchanged paths; renames are fixed
    /// up by the `rename to` line that follows.
    private static func pathFromDiffHeader(_ line: String) -> String {
        let rest = line.dropFirst("diff --git ".count)
        if let range = rest.range(of: " b/", options: .backwards) {
            return String(rest[range.upperBound...])
        }
        return String(rest)
    }

    /// "@@ -12,5 +14,7 @@ ..." → (12, 14).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }

    // MARK: - Feedback

    /// One message with every comment, ready to paste into the agent's prompt.
    static func compose(_ comments: [Comment], note: String = "") -> String {
        var out = "Review of your changes. Please address each point:\n"
        let sorted = comments.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        for (index, comment) in sorted.enumerated() {
            out += "\n\(index + 1). \(comment.file):\(comment.line)\n"
            let snippet = comment.snippet.trimmingCharacters(in: .whitespaces)
            if !snippet.isEmpty { out += "   > \(snippet)\n" }
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "   " + text.replacingOccurrences(of: "\n", with: "\n   ") + "\n"
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { out += "\n" + note + "\n" }
        return out
    }
}
