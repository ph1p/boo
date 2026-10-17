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
}
