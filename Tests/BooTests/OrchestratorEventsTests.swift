import XCTest

@testable import Boo

@MainActor
final class OrchestratorEventsTests: XCTestCase {
    /// Timers that fire only when the test says so.
    private final class Clock {
        var pending: [(TimeInterval, () -> Void)] = []
        func fireAll() {
            let due = pending
            pending.removeAll()
            for (_, body) in due { body() }
        }
    }

    private func makeEvents(capacity: Int = 500) -> (OrchestratorEvents, Clock) {
        let events = OrchestratorEvents(capacity: capacity)
        let clock = Clock()
        events.schedule = { delay, body in clock.pending.append((delay, body)) }
        return (events, clock)
    }

    private func types(_ reply: [String: Any]?) -> [String] {
        ((reply?["events"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String }
    }

    func testPendingEventsReturnAtOnce() {
        let (events, clock) = makeEvents()
        events.post("task_spawned", ["tab_id": "a"])
        var reply: [String: Any]?
        events.wait(since: 0, timeout: 60) { reply = $0 }
        XCTAssertEqual(types(reply), ["task_spawned"])
        XCTAssertEqual(reply?["seq"] as? Int, 1)
        XCTAssertEqual(reply?["missed"] as? Bool, false)
        XCTAssertTrue(clock.pending.isEmpty, "nothing held")
    }

    func testHeldReplyReturnsOnNextEventAndSinceLosesNothing() {
        let (events, clock) = makeEvents()
        events.post("a")
        var first: [String: Any]?
        events.wait(since: 1, timeout: 60) { first = $0 }
        XCTAssertNil(first, "held until something happens")
        events.post("b")
        XCTAssertEqual(types(first), ["b"])

        // Events between two calls are still there for the next one.
        events.post("c")
        events.post("d")
        var second: [String: Any]?
        events.wait(since: first?["seq"] as? Int ?? 0, timeout: 60) { second = $0 }
        XCTAssertEqual(types(second), ["c", "d"])

        clock.fireAll()
        XCTAssertEqual(types(first), ["b"], "a timer after the reply does nothing")
    }

    func testTimeoutReturnsEmptyAndIsCapped() {
        let (events, clock) = makeEvents()
        var reply: [String: Any]?
        events.wait(since: 0, timeout: 10_000) { reply = $0 }
        XCTAssertEqual(clock.pending.first?.0, OrchestratorEvents.maxTimeout)
        clock.fireAll()
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(types(reply), [])
    }

    func testRingOverflowReportsMissed() {
        let (events, _) = makeEvents(capacity: 3)
        for name in ["a", "b", "c", "d", "e"] { events.post(name) }
        var reply: [String: Any]?
        events.wait(since: 1, timeout: 60) { reply = $0 }
        XCTAssertEqual(types(reply), ["c", "d", "e"])
        XCTAssertEqual(reply?["missed"] as? Bool, true)
        events.wait(since: 2, timeout: 60) { reply = $0 }
        XCTAssertEqual(reply?["missed"] as? Bool, false, "seq 3 is the oldest kept, nothing lost")
    }

    func testSinceAheadOfSeqMeansBooRelaunched() {
        let (events, _) = makeEvents()
        events.post("a")
        var reply: [String: Any]?
        events.wait(since: 99, timeout: 60) { reply = $0 }
        XCTAssertEqual(types(reply), ["a"])
    }

    func testInboxTransitionsBecomeStateEvents() {
        let (events, _) = makeEvents()
        let owner = UUID()
        let owned = UUID()
        let other = UUID()
        CapabilityTokens.shared.markOwned(owned, by: owner)
        defer { CapabilityTokens.shared.disown(owned) }

        let inbox = AgentInbox()
        inbox.locate = { _ in nil }
        inbox.apply(event: "prompt", tabID: owned, now: Date(timeIntervalSince1970: 1))
        inbox.apply(event: "prompt", tabID: other, now: Date(timeIntervalSince1970: 2))
        events.inboxChanged(inbox.items, owner: owner)
        XCTAssertEqual(events.ring.map(\.type), ["state_changed", "state_changed"])

        events.inboxChanged(inbox.items, owner: owner)
        XCTAssertEqual(events.ring.count, 2, "no change, no event")

        inbox.apply(event: "stop", tabID: owned)
        inbox.apply(event: "stop", tabID: other)
        events.inboxChanged(inbox.items, owner: owner)
        let finished = events.ring.filter { $0.type == "task_finished" }
        XCTAssertEqual(finished.map { $0.data["tab_id"] as? String }, [owned.uuidString], "only owned tasks finish")
        let ownedDone = events.ring.last {
            $0.type == "state_changed" && $0.data["tab_id"] as? String == owned.uuidString
        }
        XCTAssertEqual(ownedDone?.data["owned"] as? Bool, true)
        XCTAssertEqual(ownedDone?.data["previous"] as? String, "working")

        inbox.remove(tabID: other)
        events.inboxChanged(inbox.items, owner: owner)
        XCTAssertEqual(events.ring.last?.data["state"] as? String, "ended")
    }

    func testSocketCommandDefaultsSinceToNow() {
        let (events, clock) = makeEvents()
        events.post("old")
        var reply: [String: Any]?
        events.handleSocketCommand(["timeout": 5]) { reply = $0 }
        XCTAssertNil(reply, "without since, only new events count")
        XCTAssertEqual(clock.pending.first?.0, 5)
        events.post("new")
        XCTAssertEqual(types(reply), ["new"])
    }

    func testMCPClientWaitsLongerForHeldReplies() {
        XCTAssertEqual(BooMCPServer.clientTimeout(for: ["cmd": "get_layout"]), 10)
        XCTAssertEqual(BooMCPServer.clientTimeout(for: ["cmd": "wait_for_events", "timeout": 60]), 75)
        XCTAssertEqual(
            BooMCPServer.clientTimeout(for: ["cmd": "wait_for_events"]), Int(OrchestratorEvents.defaultTimeout) + 15)
        XCTAssertEqual(
            BooMCPServer.clientTimeout(for: ["cmd": "wait_for_events", "timeout": 9_999]),
            Int(OrchestratorEvents.maxTimeout) + 15)
    }
}
