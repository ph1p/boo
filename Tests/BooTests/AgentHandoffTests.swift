import XCTest

@testable import Boo

final class AgentHandoffTests: XCTestCase {
    func testOutputBetweenMultiLinePrompts() {
        let screen = """
            (ctx)
            ~/app on main
            ➜ ls
            old
            (ctx)
            ~/app on main
            ➜ pnpm test
            FAIL a.test.ts
              expected 1, got 2

            (ctx)
            ~/app on main
            ➜\u{20}\u{20}


            """
        XCTAssertEqual(
            AgentHandoff.output(of: "pnpm test", in: screen), "FAIL a.test.ts\n  expected 1, got 2")
    }

    func testOutputWithSingleLinePromptAndBlankSeparator() {
        let screen = "\n$ make\ncc main.c\nmain.c:3: error: x\n\n$ "
        XCTAssertEqual(AgentHandoff.output(of: "make", in: screen), "cc main.c\nmain.c:3: error: x")
    }

    func testPicksLastRunAndHandlesNoOutput() {
        XCTAssertEqual(AgentHandoff.output(of: "date", in: "$ date\nMon\n$ date\nTue\n$"), "Tue")
        let screen = "$ date\nMon\n$ true\n$"
        XCTAssertEqual(AgentHandoff.output(of: "true", in: screen), "")
        XCTAssertNil(AgentHandoff.output(of: "cargo build", in: screen))
        XCTAssertNil(AgentHandoff.output(of: "  ", in: screen))
    }

    func testRunningCommandKeepsLastLines() {
        let screen = "$ pnpm dev\nready on :3000\nerror: port in use"
        XCTAssertEqual(
            AgentHandoff.output(of: "pnpm dev", in: screen, finished: false), "ready on :3000\nerror: port in use")
    }

    func testMultiLineCommandSkipsItsContinuationLines() {
        let screen = "$ for f in a b; do\n> echo $f\n> done\na\nb\n$"
        XCTAssertEqual(AgentHandoff.output(of: "for f in a b; do\necho $f\ndone", in: screen), "a\nb")
    }

    func testComposeHeadersAndFences() {
        XCTAssertEqual(
            AgentHandoff.compose(
                "boom", source: .output(command: "pnpm test\n--watch", exitCode: 1), cwd: "/tmp/app"),
            "Output of `pnpm test` (exit code 1) in /tmp/app:\n```\nboom\n```\n")
        XCTAssertEqual(
            AgentHandoff.compose("ok", source: .output(command: "make", exitCode: 0), cwd: nil),
            "Output of `make`:\n```\nok\n```\n")
        XCTAssertTrue(
            AgentHandoff.compose("x", source: .output(command: "dev", exitCode: nil), cwd: nil)
                .hasPrefix("Output of `dev` (still running):"))
        XCTAssertEqual(
            AgentHandoff.compose("use ```js``` here", source: .selection, cwd: nil),
            "From my terminal:\n````\nuse ```js``` here\n````\n", "fence outlasts backticks in the text")
    }

    func testComposeKeepsTheEndOfLongOutput() {
        let long = (1...20_000).map { "line \($0)" }.joined(separator: "\n")
        let message = AgentHandoff.compose(long, source: .selection, cwd: nil)
        XCTAssertTrue(message.hasPrefix("From my terminal: (end only, it was longer)\n```\nline "))
        XCTAssertTrue(message.hasSuffix("line 20000\n```\n"))
        XCTAssertLessThan(message.count, AgentHandoff.maxCharacters + 200)
    }
}
