import SwiftUI
import XCTest

@testable import Boo

/// Crew rows behave like a sidebar: a click selects the row and shows the agent.
/// Real mouse events through a hosting window, so SwiftUI's gestures run.
@MainActor
final class AgentCrewClickTests: XCTestCase {
    private func click(_ window: NSWindow, at point: NSPoint, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// Hosts the crew list in a borderless window as tall as the list.
    private func host(_ view: AgentCrewView) -> (NSWindow, CGFloat) {
        let hosting = NSHostingView(rootView: view.frame(width: 260))
        let height = hosting.fittingSize.height
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (window, height)
    }

    private func crew(_ rows: [AgentCrewRow], onJump: @escaping (AgentCrewRow) -> Void = { _ in }) -> AgentCrewView {
        AgentCrewView(
            rows: rows, fontScale: SidebarFontScale(base: 13, fontName: ""),
            textColor: .white, mutedColor: .gray, accentColor: .blue,
            onJump: onJump, onReview: { _ in }, onMerge: { _ in }, onDiscard: { _ in })
    }

    func testClickSelectsAndJumps() {
        let row = AgentCrewRow(
            id: UUID(), handle: "t1", name: "main", agent: "claude", state: .working, detail: "using Bash",
            parent: nil, queued: 0, needsAttention: false, isTask: false)
        var jumps = 0
        let (window, height) = host(crew([row]) { _ in jumps += 1 })
        defer { window.orderOut(nil) }
        let saved = AgentCrewUIState.shared.selection
        defer { AgentCrewUIState.shared.selection = saved }
        AgentCrewUIState.shared.selection = nil

        // The "Outside Boo" group header takes the top 27pt; click the row's name line under it.
        click(window, at: NSPoint(x: 120, y: height - 42), count: 1)
        XCTAssertEqual(AgentCrewUIState.shared.selection, row.id, "a click selects")
        XCTAssertEqual(jumps, 1, "a click shows the agent")
    }

    /// Like a sidebar list: a click on empty space under the rows drops the selection.
    func testClickOnEmptySpaceDeselects() {
        let row = AgentCrewRow(
            id: UUID(), handle: "t1", name: "main", agent: "claude", state: .working, detail: "using Bash",
            parent: nil, queued: 0, needsAttention: false, isTask: false)
        var jumps = 0
        let (window, _) = host(crew([row]) { _ in jumps += 1 })
        defer { window.orderOut(nil) }
        let saved = AgentCrewUIState.shared.selection
        defer { AgentCrewUIState.shared.selection = saved }
        AgentCrewUIState.shared.selection = row.id

        // The list's bottom padding: no row, no header.
        click(window, at: NSPoint(x: 120, y: 3), count: 1)
        XCTAssertNil(AgentCrewUIState.shared.selection, "a click outside the rows deselects")
        XCTAssertEqual(jumps, 0)
    }
}
