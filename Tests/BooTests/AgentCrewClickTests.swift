import SwiftUI
import XCTest

@testable import Boo

/// Crew rows behave like a source list: a click selects, a double-click jumps.
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

    func testClickSelectsDoubleClickJumps() {
        let row = AgentCrewRow(
            id: UUID(), handle: "t1", name: "main", agent: "claude", state: .working, detail: "using Bash",
            parent: nil, queued: 0, needsAttention: false, isTask: false)
        var jumps = 0
        let view = AgentCrewView(
            rows: [row], fontScale: SidebarFontScale(base: 13, fontName: ""),
            textColor: .white, mutedColor: .gray, accentColor: .blue,
            onJump: { _ in jumps += 1 }, onReview: { _ in }, onMerge: { _ in }, onDiscard: { _ in })
            .frame(width: 260, height: 300, alignment: .top)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let saved = AgentCrewUIState.shared.selection
        defer { AgentCrewUIState.shared.selection = saved }
        AgentCrewUIState.shared.selection = nil

        // The row sits below the "Working" group header; click its name line.
        let point = NSPoint(x: 120, y: 300 - 40)
        click(window, at: point, count: 1)
        XCTAssertEqual(AgentCrewUIState.shared.selection, row.id, "a click selects")
        XCTAssertEqual(jumps, 0, "a click does not jump")

        click(window, at: point, count: 2)
        XCTAssertEqual(jumps, 1, "a double-click jumps")
    }
}
