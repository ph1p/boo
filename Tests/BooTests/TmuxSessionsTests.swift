import XCTest

@testable import Boo

final class TmuxSessionsTests: XCTestCase {
    func testParsesSessionList() {
        let output = "main\t3\t1\nmy work\t1\t0\nbroken line\n\tx\t0\n"
        XCTAssertEqual(
            TmuxSessions.parse(output),
            [
                .init(name: "main", windows: 3, attached: true),
                .init(name: "my work", windows: 1, attached: false)
            ])
        XCTAssertEqual(TmuxSessions.parse(""), [])
    }

    func testSummary() {
        XCTAssertEqual(TmuxSessions.Session(name: "a", windows: 1, attached: false).summary, "1 window")
        XCTAssertEqual(
            TmuxSessions.Session(name: "a", windows: 2, attached: true).summary, "2 windows, attached elsewhere")
    }

    func testCommands() {
        XCTAssertEqual(TmuxSessions.command(attach: nil, host: nil), "command tmux -CC new-session")
        XCTAssertEqual(
            TmuxSessions.command(attach: "it's", host: nil), "command tmux -CC new-session -A -s 'it'\\''s'")
        XCTAssertEqual(
            TmuxSessions.command(attach: "main", host: "web"),
            "ssh -t 'web' 'tmux -CC new-session -A -s '\\''main'\\'''")
    }
}
