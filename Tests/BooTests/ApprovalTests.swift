import XCTest

@testable import Boo

@MainActor
final class ApprovalTests: XCTestCase {
    private let caller = UUID()
    private let agent = UUID()

    /// Inbox stamps and open tabs the center sees.
    private final class World {
        var stamps: [UUID: Double] = [:]
        var open: Set<UUID> = []
    }

    private final class Log {
        var outcomes: [ApprovalCenter.Outcome] = []
        var replies: [[String: Any]?] = []
        var runs = 0
    }

    private func makeCenter(_ world: World, _ log: Log) -> ApprovalCenter {
        let center = ApprovalCenter()
        center.stamp = { world.stamps[$0] }
        center.tabExists = { world.open.contains($0) }
        center.onResolved = { _, outcome, reply in
            log.outcomes.append(outcome)
            log.replies.append(reply)
        }
        return center
    }

    @discardableResult
    private func enqueue(_ center: ApprovalCenter, _ log: Log, _ cmd: String = "send_text") -> ApprovalCenter.Request {
        center.enqueue(cmd: cmd, json: ["text": "yes", "submit": true], caller: caller, targets: [agent]) { done in
            log.runs += 1
            done(["ok": true])
        }
    }

    func testAllowRunsTheCommandAndReportsItsReply() {
        let world = World()
        world.stamps[agent] = 100
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        let request = enqueue(center, log)
        XCTAssertEqual(request.action, "Type into pane")
        XCTAssertEqual(request.payload, "yes ⏎")
        XCTAssertEqual(center.pending.count, 1)

        center.resolve(request.id, allow: true)
        XCTAssertEqual(log.runs, 1)
        XCTAssertEqual(log.outcomes, [.allowed])
        XCTAssertEqual(log.replies.first??["ok"] as? Bool, true)
        XCTAssertTrue(center.pending.isEmpty)

        center.resolve(request.id, allow: true)
        XCTAssertEqual(log.runs, 1, "a resolved card does nothing")
    }

    func testDenySendsNothing() {
        let world = World()
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        let request = enqueue(center, log)
        center.resolve(request.id, allow: false)
        XCTAssertEqual(log.runs, 0)
        XCTAssertEqual(log.outcomes, [.denied])
    }

    func testStaleUpdatedAtResolvesStaleAndSendsNothing() {
        let world = World()
        world.stamps[agent] = 100
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        let request = enqueue(center, log)
        world.stamps[agent] = 101
        center.resolve(request.id, allow: true)
        XCTAssertEqual(log.runs, 0)
        XCTAssertEqual(log.outcomes, [.stale])
    }

    func testRevalidateExpiresCardsForChangedOrClosedTabs() {
        let world = World()
        world.stamps[agent] = 100
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        enqueue(center, log)
        center.revalidate()
        XCTAssertEqual(center.pending.count, 1, "nothing changed")
        world.open = []
        center.revalidate()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(log.outcomes, [.stale])
    }

    func testAllowForThisTabGrantsLaterWritesButNeverForMerge() {
        let world = World()
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        let request = enqueue(center, log)
        XCTAssertTrue(request.allowsTabGrant)
        center.resolve(request.id, allow: true, forTab: true)
        XCTAssertTrue(center.isGranted(caller: caller, tab: agent))
        XCTAssertFalse(center.isGranted(caller: UUID(), tab: agent), "grants are per caller")
        center.revokeGrants(tab: agent)
        XCTAssertFalse(center.isGranted(caller: caller, tab: agent))

        let merge = enqueue(center, log, "merge_task")
        XCTAssertFalse(merge.allowsTabGrant)
        center.resolve(merge.id, allow: true, forTab: true)
        XCTAssertFalse(center.isGranted(caller: caller, tab: agent))
    }

    func testExpireAllResolvesEveryCardStale() {
        let world = World()
        world.open = [agent]
        let log = Log()
        let center = makeCenter(world, log)
        enqueue(center, log)
        enqueue(center, log, "agent_respond")
        center.expireAll()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(log.outcomes, [.stale, .stale])
        XCTAssertEqual(log.runs, 0)
    }
}
