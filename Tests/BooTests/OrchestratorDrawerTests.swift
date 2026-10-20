import XCTest

@testable import Boo

@MainActor
final class OrchestratorDrawerTests: XCTestCase {
    func testEnqueueAnnouncesTheCard() {
        let center = ApprovalCenter()
        var announced: [String] = []
        center.onEnqueued = { announced.append($0.action) }
        center.enqueue(cmd: "send_text", json: ["text": "y"], caller: UUID(), targets: [UUID()]) { $0(["ok": true]) }
        XCTAssertEqual(announced, ["Type into pane"])
    }

    func testTargetLabelNamesTheAgent() {
        let inbox = AgentInbox()
        inbox.locate = { _ in nil }
        let tab = UUID()
        inbox.apply(event: "stop", tabID: tab)
        XCTAssertEqual(OrchestratorController.targetLabel([tab], inbox: inbox), AgentInbox.displayName(of: "claude"))
        XCTAssertEqual(OrchestratorController.targetLabel([UUID()], inbox: inbox), "Pane")
        XCTAssertEqual(OrchestratorController.targetLabel([], inbox: inbox), "")
    }

    func testWidthIsClamped() {
        let drawer = OrchestratorDrawerView(frame: .zero)
        XCTAssertEqual(drawer.clampedWidth(100), OrchestratorDrawerView.minWidth)
        XCTAssertEqual(drawer.clampedWidth(450), 450)
        XCTAssertLessThanOrEqual(drawer.clampedWidth(5000), OrchestratorDrawerView.maxWidth)
    }
}
