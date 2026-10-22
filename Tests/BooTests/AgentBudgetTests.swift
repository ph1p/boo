import XCTest

@testable import Boo

final class AgentBudgetTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(BudgetLevel.of(cost: 100, budget: nil), .ok)
        XCTAssertEqual(BudgetLevel.of(cost: 7.99, budget: 10), .ok)
        XCTAssertEqual(BudgetLevel.of(cost: 8, budget: 10), .warning)
        XCTAssertEqual(BudgetLevel.of(cost: 10, budget: 10), .over)
        XCTAssertEqual(BudgetLevel.of(cost: 12, budget: 10), .over)
    }

    func testCrossingNotifiesOnce() {
        var crossings = BudgetCrossings()
        XCTAssertFalse(crossings.update("day", cost: 5, budget: 10))
        XCTAssertFalse(crossings.update("day", cost: 9, budget: 10), "amber does not notify")
        XCTAssertTrue(crossings.update("day", cost: 10.5, budget: 10))
        XCTAssertFalse(crossings.update("day", cost: 11, budget: 10), "only once per crossing")
        XCTAssertFalse(crossings.update("task:a", cost: 1, budget: 10), "keys are independent")
        XCTAssertTrue(crossings.update("task:a", cost: 20, budget: 10))
    }

    func testRaisedBudgetRearms() {
        var crossings = BudgetCrossings()
        XCTAssertTrue(crossings.update("day", cost: 10, budget: 10))
        XCTAssertFalse(crossings.update("day", cost: 10, budget: 20))
        XCTAssertTrue(crossings.update("day", cost: 21, budget: 20))
        XCTAssertFalse(crossings.update("day", cost: 30, budget: nil), "off never notifies")
        crossings.reset()
        XCTAssertTrue(crossings.update("day", cost: 30, budget: 20), "new day notifies again")
    }

    func testCostSinceDayStart() {
        let dayStart = Date(timeIntervalSince1970: 1_000_000)
        var timeline = AgentTimeline()
        timeline.start = dayStart.addingTimeInterval(-3600)
        timeline.cost = 5
        var old = AgentTimeline.Turn(id: 0, kind: .prompt, prompt: "a")
        old.start = dayStart.addingTimeInterval(-60)
        old.cost = 2
        var new = AgentTimeline.Turn(id: 1, kind: .prompt, prompt: "b")
        new.start = dayStart.addingTimeInterval(60)
        new.cost = 3
        timeline.turns = [old, new]
        XCTAssertEqual(AgentBudget.cost(of: timeline, since: dayStart), 3, accuracy: 0.001)

        timeline.start = dayStart
        XCTAssertEqual(
            AgentBudget.cost(of: timeline, since: dayStart), 5, accuracy: 0.001, "whole session started today")
    }

    func testFormat() {
        XCTAssertEqual(AgentBudget.format(1.234), "$1.23")
        XCTAssertEqual(AgentBudget.format(12.6), "$13")
    }
}
