import XCTest

@testable import Exterm

final class DSLActionHandlerTests: XCTestCase {

    func testCdAction() {
        let handler = DSLActionHandler()
        var sentCommand: String?
        handler.sendToTerminal = { sentCommand = $0 }

        let result = handler.handle(DSLAction(type: "cd", path: "/var/log", command: nil, text: nil))

        XCTAssertEqual(sentCommand, "cd /var/log\r")
        XCTAssertEqual(result, "Changed directory to /var/log")
    }

    func testCdActionWithSpaces() {
        let handler = DSLActionHandler()
        var sentCommand: String?
        handler.sendToTerminal = { sentCommand = $0 }

        handler.handle(DSLAction(type: "cd", path: "/Users/test/My Project", command: nil, text: nil))

        XCTAssertEqual(sentCommand, "cd '/Users/test/My Project'\r")  // space requires quoting
    }

    func testExecAction() {
        let handler = DSLActionHandler()
        var sentCommand: String?
        handler.sendToTerminal = { sentCommand = $0 }

        let result = handler.handle(DSLAction(type: "exec", path: nil, command: "git status", text: nil))

        XCTAssertEqual(sentCommand, "git status\r")
        XCTAssertNil(result)  // terminal output IS the feedback
    }

    func testCopyAction() {
        let handler = DSLActionHandler()

        let result = handler.handle(DSLAction(type: "copy", path: nil, command: nil, text: "hello world"))

        XCTAssertEqual(result, "Copied to clipboard")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello world")
    }

    func testCopyActionFromPath() {
        let handler = DSLActionHandler()

        let result = handler.handle(DSLAction(type: "copy", path: "/some/path", command: nil, text: nil))

        XCTAssertEqual(result, "Copied to clipboard")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/some/path")
    }

    func testEmptyPathReturnsNil() {
        let handler = DSLActionHandler()
        var sentCommand: String?
        handler.sendToTerminal = { sentCommand = $0 }

        let result = handler.handle(DSLAction(type: "cd", path: "", command: nil, text: nil))

        XCTAssertNil(sentCommand)
        XCTAssertNil(result)
    }

    func testUnknownActionReturnsNil() {
        let handler = DSLActionHandler()
        let result = handler.handle(DSLAction(type: "unknown", path: nil, command: nil, text: nil))
        XCTAssertNil(result)
    }
}
