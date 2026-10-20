import XCTest

@testable import Boo

@MainActor
final class CommandBlocksTests: XCTestCase {
    func testGutterColorsFollowStatus() {
        let theme = AppSettings.shared.theme
        XCTAssertEqual(PromptGutterView.color(for: .failed, theme: theme), theme.error)
        XCTAssertEqual(PromptGutterView.color(for: .none, theme: theme), theme.focusBorder)
        XCTAssertNotEqual(PromptGutterView.color(for: .succeeded, theme: theme), theme.error)
    }

    func testGutterIgnoresMouse() {
        let gutter = PromptGutterView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(gutter.hitTest(NSPoint(x: 1, y: 1)))
    }

    func testShortCommandTitle() {
        XCTAssertEqual(AgentHandoffMenuTarget.short("ls -la"), "ls -la")
        let long = String(repeating: "x", count: 40)
        XCTAssertEqual(AgentHandoffMenuTarget.short(long), String(repeating: "x", count: 29) + "…")
    }

    func testViewWithoutSurfaceHasNoBlocks() {
        let view = GhosttyView(workingDirectory: "/tmp")
        view.destroy()
        XCTAssertEqual(view.promptMarks(), [])
        XCTAssertNil(view.promptIndex(atViewportRow: 0))
        XCTAssertNil(view.readCommand(index: 0, part: .output))
        XCTAssertNil(view.lastCommandIndex())
    }
}
