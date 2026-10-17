import XCTest

@testable import Boo

@MainActor
final class AgentInboxRemoteTests: XCTestCase {
    private var sent: [(UUID, AgentInbox.Response)] = []

    private func makeInbox(terminalOpen: Bool = true) -> AgentInbox {
        let inbox = AgentInbox()
        inbox.locate = { _ in nil }
        inbox.sendResponse = { [unowned self] tab, response in
            guard terminalOpen else { return false }
            sent.append((tab, response))
            return true
        }
        return inbox
    }

    private func waiting(_ inbox: AgentInbox) -> (UUID, Double) {
        let tab = UUID()
        inbox.apply(event: "permission", tabID: tab, message: "Claude needs your permission to use Bash")
        return (tab, inbox.items[tab]!.updatedAt.timeIntervalSince1970)
    }

    func testApproveTypesReturnAndMarksWorking() {
        let inbox = makeInbox()
        let (tab, shown) = waiting(inbox)
        let reply = inbox.respond(["tab_id": tab.uuidString, "response": "approve", "updated_at": shown])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(sent.map(\.1), [.approve])
        XCTAssertEqual(sent.first?.0, tab)
        XCTAssertEqual(inbox.items[tab]?.state, .working)
        XCTAssertEqual(inbox.attentionCount, 0)
    }

    func testDenyTypesEscapeAndLeavesAgentDoneAndSeen() {
        let inbox = makeInbox()
        let (tab, _) = waiting(inbox)
        let reply = inbox.handleSocketCommand(
            cmd: "agent_respond", json: ["tab_id": tab.uuidString, "response": "deny"])
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(sent.map(\.1), [.deny])
        XCTAssertEqual(inbox.items[tab]?.state, .done)
        XCTAssertEqual(inbox.items[tab]?.message, "Denied from remote control")
        XCTAssertEqual(inbox.attentionCount, 0)
    }

    func testRefusesWhenNothingWaitsOrTheQuestionChanged() {
        let inbox = makeInbox()
        let (tab, shown) = waiting(inbox)

        var reply = inbox.respond(["tab_id": tab.uuidString, "response": "approve", "updated_at": shown - 5])
        XCTAssertEqual(reply["ok"] as? Bool, false, "an answer to an older question is dropped")
        reply = inbox.respond(["tab_id": tab.uuidString, "response": "maybe"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        reply = inbox.respond(["response": "approve"])
        XCTAssertEqual(reply["ok"] as? Bool, false)

        inbox.apply(event: "tool", tabID: tab)
        reply = inbox.respond(["tab_id": tab.uuidString, "response": "approve"])
        XCTAssertEqual(reply["ok"] as? Bool, false, "a working agent is not typed into")
        XCTAssertTrue(sent.isEmpty)
    }

    func testClosedTerminalKeepsTheRequest() {
        let inbox = makeInbox(terminalOpen: false)
        let (tab, _) = waiting(inbox)
        let reply = inbox.respond(["tab_id": tab.uuidString, "response": "approve"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(inbox.items[tab]?.state, .needsInput)
    }

    func testPreviewKeepsTheEndWithoutTrailingBlanks() {
        let screen = (1...30).map { "line \($0)   " }.joined(separator: "\n") + "\n\n   \n"
        let preview = AgentInbox.preview(of: screen, lines: 3)
        XCTAssertEqual(preview, "line 28\nline 29\nline 30")
        XCTAssertEqual(AgentInbox.preview(of: "\n\n"), "")
    }
}
