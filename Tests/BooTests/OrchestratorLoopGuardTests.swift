import XCTest

@testable import Boo

@MainActor
final class OrchestratorLoopGuardTests: XCTestCase {
    func testTripsAfterThresholdWritesWithoutChange() {
        let guardian = OrchestratorLoopGuard()
        let tab = UUID()
        for _ in 0..<AgentTimeline.loopThreshold {
            XCTAssertFalse(guardian.record([tab]))
        }
        XCTAssertTrue(guardian.record([tab]))
        // Tripping does not count: it stays tripped until something resets it.
        XCTAssertTrue(guardian.record([tab]))
        XCTAssertEqual(guardian.count(tab), AgentTimeline.loopThreshold)
    }

    func testStateChangeResets() {
        let guardian = OrchestratorLoopGuard()
        let tab = UUID()
        for _ in 0..<AgentTimeline.loopThreshold { _ = guardian.record([tab]) }
        guardian.reset(tab)
        XCTAssertFalse(guardian.record([tab]))
    }

    func testTabsAreCountedSeparately() {
        let guardian = OrchestratorLoopGuard()
        let a = UUID()
        for _ in 0..<AgentTimeline.loopThreshold { _ = guardian.record([a]) }
        XCTAssertFalse(guardian.record([UUID()]))
        XCTAssertTrue(guardian.record([a]))
    }

    func testLoopCardOffersNoTabGrant() {
        let center = ApprovalCenter()
        let request = center.enqueue(
            cmd: "send_text", json: ["text": "go on"], caller: UUID(), targets: [UUID()], loop: true
        ) { $0(["ok": true]) }
        XCTAssertEqual(request.action, "Possible loop · Type into pane")
        XCTAssertFalse(request.allowsTabGrant)
    }
}
