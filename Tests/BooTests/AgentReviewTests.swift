import XCTest

@testable import Boo

final class AgentReviewTests: XCTestCase {
    func testParsesModifiedAddedDeletedRenamedAndBinary() {
        let diff = """
            diff --git a/src/app.swift b/src/app.swift
            index 1111111..2222222 100644
            --- a/src/app.swift
            +++ b/src/app.swift
            @@ -3,4 +3,5 @@ struct App {
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             let d = 5
            \\ No newline at end of file
            @@ -20 +21 @@
            -old
            +new
            diff --git a/new file.txt b/new file.txt
            new file mode 100644
            --- /dev/null
            +++ b/new file.txt
            @@ -0,0 +1 @@
            +hello
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old/name.txt b/new/name.txt
            similarity index 100%
            rename from old/name.txt
            rename to new/name.txt
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """
        let files = AgentReview.parse(diff)
        XCTAssertEqual(files.map(\.path), ["src/app.swift", "new file.txt", "gone.txt", "new/name.txt", "logo.png"])

        let app = files[0]
        XCTAssertEqual(app.hunks.count, 2)
        XCTAssertEqual(app.additions, 3)
        XCTAssertEqual(app.deletions, 2)
        XCTAssertEqual(
            app.hunks[0].lines,
            [
                .init(kind: .context, oldLine: 3, newLine: 3, text: "let a = 1"),
                .init(kind: .removed, oldLine: 4, newLine: nil, text: "let b = 2"),
                .init(kind: .added, oldLine: nil, newLine: 4, text: "let b = 3"),
                .init(kind: .added, oldLine: nil, newLine: 5, text: "let c = 4"),
                .init(kind: .context, oldLine: 5, newLine: 6, text: "let d = 5")
            ])
        XCTAssertEqual(app.hunks[1].lines.map(\.newLine), [nil, 21])

        XCTAssertEqual(files[1].status, .added)
        XCTAssertEqual(files[2].status, .deleted)
        XCTAssertEqual(files[3].status, .renamed)
        XCTAssertEqual(files[3].oldPath, "old/name.txt")
        XCTAssertTrue(files[4].isBinary)
        XCTAssertTrue(AgentReview.parse("").isEmpty)
    }

    func testComposeSortsAndIndents() {
        let comments: [AgentReview.Comment] = [
            .init(file: "b.swift", line: 9, snippet: "  return x", text: "Handle nil.\nAlso log it."),
            .init(file: "a.swift", line: 2, snippet: "", text: "Rename this.")
        ]
        XCTAssertEqual(
            AgentReview.compose(comments, note: " Run the tests after. "),
            """
            Review of your changes. Please address each point:

            1. a.swift:2
               Rename this.

            2. b.swift:9
               > return x
               Handle nil.
               Also log it.

            Run the tests after.

            """)
    }

    func testChangesInWorktreeIncludeCommittedUncommittedAndUntracked() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
            .replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)
        let sandbox = (base as NSString).appendingPathComponent("boo-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: sandbox) }
        let repo = (sandbox as NSString).appendingPathComponent("repo")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String..., in dir: String) throws {
            try AgentWorktree.git(
                ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false"] + args, in: dir)
        }
        func write(_ file: String, _ text: String, in dir: String) throws {
            try text.write(toFile: (dir as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try git("init", "-q", "-b", "main", in: repo)
        try write("a.txt", "one\n", in: repo)
        try git("add", ".", in: repo)
        try git("commit", "-q", "-m", "init", in: repo)

        XCTAssertEqual(try AgentReview.changes(in: repo).files, [], "a clean checkout has nothing to review")

        let task = try AgentWorktree.create(
            repo: repo, name: "review", root: (sandbox as NSString).appendingPathComponent("wt"))
        try write("a.txt", "one\ntwo\n", in: task.path)
        try git("commit", "-qam", "two", in: task.path)
        try write("a.txt", "one\ntwo\nthree\n", in: task.path)
        try write("b.txt", "fresh\n", in: task.path)
        // The main branch moving on must not show up as the agent's change.
        try write("main-only.txt", "x\n", in: repo)
        try git("add", ".", in: repo)
        try git("commit", "-q", "-m", "main moves", in: repo)

        let changes = try AgentReview.changes(in: task.path)
        XCTAssertEqual(changes.base, "main")
        XCTAssertEqual(changes.branch, "boo/review")
        XCTAssertEqual(changes.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(changes.files[0].additions, 2, "committed and uncommitted lines together")
        XCTAssertEqual(changes.files[1].status, .added)
        XCTAssertEqual(changes.files[1].hunks.first?.lines.map(\.text), ["fresh"])
    }

    func testUnstagedAndStagedSourcesAndContext() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let repo = (base as NSString).appendingPathComponent("boo-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try AgentWorktree.git(
                ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false"] + args, in: repo)
        }
        func write(_ file: String, _ text: String) throws {
            try text.write(toFile: (repo as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try git("init", "-q", "-b", "main")
        try write("a.txt", (1...9).map { "line \($0)\n" }.joined())
        try write("s.txt", "old\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "init")

        try write("a.txt", (1...9).map { $0 == 5 ? "five\n" : "line \($0)\n" }.joined())
        try write("s.txt", "new\n")
        try git("add", "s.txt")
        try write("u.txt", "untracked\n")

        let unstaged = try AgentReview.changes(in: repo, source: .unstaged)
        XCTAssertEqual(unstaged.files.map(\.path), ["a.txt", "u.txt"], "work tree changes and untracked files")
        XCTAssertNil(unstaged.branch)
        XCTAssertEqual(unstaged.files[0].hunks.first?.lines.count, 8, "three lines of context by default")

        let staged = try AgentReview.changes(in: repo, source: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["s.txt"], "only the index, no untracked files")
        XCTAssertEqual(staged.files[0].hunks.first?.lines.map(\.text), ["old", "new"])

        let tight = try AgentReview.changes(in: repo, source: .unstaged, context: 0)
        XCTAssertEqual(tight.files[0].hunks.first?.lines.map(\.text), ["line 5", "five"])
        let wide = try AgentReview.changes(in: repo, source: .unstaged, context: 20)
        XCTAssertEqual(wide.files[0].hunks.first?.lines.count, 10, "the whole file")
    }

    func testStagedOnUnbornBranch() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let repo = (base as NSString).appendingPathComponent("boo-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try AgentWorktree.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(toFile: (repo as NSString).appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try AgentWorktree.git(["add", "x.txt"], in: repo)
        let staged = try AgentReview.changes(in: repo, source: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["x.txt"])
        XCTAssertEqual(staged.files[0].status, .added)
    }

    func testSplitRowsPairChangesAndKeepContextOnBothSides() {
        func line(_ kind: AgentReview.DiffLine.Kind, _ text: String, _ old: Int?, _ new: Int?) -> AgentReview.DiffLine {
            AgentReview.DiffLine(kind: kind, oldLine: old, newLine: new, text: text)
        }
        let ctx = line(.context, "c", 1, 1)
        let r1 = line(.removed, "r1", 2, nil)
        let r2 = line(.removed, "r2", 3, nil)
        let a1 = line(.added, "a1", nil, 2)
        let a2 = line(.added, "a2", nil, 3)
        let a3 = line(.added, "a3", nil, 4)
        let r3 = line(.removed, "r3", 4, nil)
        let rows = AgentReview.splitRows([ctx, r1, r2, a1, a2, a3, ctx, a1, r3])
        XCTAssertEqual(
            rows,
            [
                .init(left: ctx, right: ctx),
                .init(left: r1, right: a1), .init(left: r2, right: a2), .init(left: nil, right: a3),
                .init(left: ctx, right: ctx),
                // An addition then a removal are two changes, not one pair.
                .init(left: nil, right: a1), .init(left: r3, right: nil),
            ])
        XCTAssertEqual(AgentReview.splitRows([]), [])
    }

    func testDiffContextSettingIsClamped() {
        XCTAssertEqual(DiffSettings.clampedContext(3), 3)
        XCTAssertEqual(DiffSettings.clampedContext(-4), 0)
        XCTAssertEqual(DiffSettings.clampedContext(99), DiffSettings.maxContext)
        XCTAssertEqual(DiffSettings.clampedContext(2.6), 3)
        XCTAssertEqual(DiffSettings.clampedContext(.nan), AgentReview.defaultContext)
    }
}
