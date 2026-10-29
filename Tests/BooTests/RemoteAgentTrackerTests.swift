import XCTest

@testable import Boo

@MainActor
final class RemoteAgentTrackerTests: XCTestCase {
    private func makeTracker(remote: Bool = true) -> (RemoteAgentTracker, AgentInbox) {
        let inbox = AgentInbox()
        inbox.locate = { _ in nil }
        let tracker = RemoteAgentTracker(inbox: inbox, isRemoteShell: { _ in remote })
        return (tracker, inbox)
    }

    func testParseTitleStates() {
        XCTAssertEqual(RemoteAgentTracker.parse(title: "✳ Claude Code")?.state, .idle)
        XCTAssertEqual(RemoteAgentTracker.parse(title: "⠂ Fix the login bug")?.state, .working)
        XCTAssertEqual(RemoteAgentTracker.parse(title: "◐ Refactor")?.agent, "claude")
        XCTAssertNil(RemoteAgentTracker.parse(title: "user@host: ~/dev"))
        XCTAssertNil(RemoteAgentTracker.parse(title: "~/.claude"))
    }

    func testRemoteAgentLifecycle() {
        let (tracker, inbox) = makeTracker()
        let tab = UUID()

        tracker.titleChanged(tabID: tab, title: "⠂ Fix the login bug", shellPID: 1)
        XCTAssertEqual(inbox.items[tab]?.state, .working)

        tracker.titleChanged(tabID: tab, title: "✳ Fix the login bug", shellPID: 1)
        XCTAssertEqual(inbox.items[tab]?.state, .done)

        tracker.attentionRequested(tabID: tab, message: "Claude needs your permission")
        XCTAssertEqual(inbox.items[tab]?.state, .needsInput)
        XCTAssertEqual(inbox.items[tab]?.message, "Claude needs your permission")

        tracker.titleChanged(tabID: tab, title: "⠐ Fix the login bug", shellPID: 1)
        XCTAssertEqual(inbox.items[tab]?.state, .working)

        tracker.titleChanged(tabID: tab, title: "user@box: ~/app", shellPID: 1)
        XCTAssertNil(inbox.items[tab], "a shell title ends the agent")
        XCTAssertNil(tracker.tracked[tab])
    }

    func testIdleTitleKeepsNeedsInput() {
        let (tracker, inbox) = makeTracker()
        let tab = UUID()
        tracker.titleChanged(tabID: tab, title: "⠂ Task", shellPID: 1)
        tracker.attentionRequested(tabID: tab)
        tracker.titleChanged(tabID: tab, title: "✳ Task", shellPID: 1)
        XCTAssertEqual(inbox.items[tab]?.state, .needsInput)
    }

    func testIgnoresLocalAndHookFedTabs() {
        let (local, localInbox) = makeTracker(remote: false)
        let tab = UUID()
        local.titleChanged(tabID: tab, title: "⠂ Task", shellPID: 1)
        XCTAssertNil(localInbox.items[tab], "a local agent is reported by its hooks")
        local.attentionRequested(tabID: tab)
        XCTAssertNil(localInbox.items[tab], "a bell in an untracked tab is not an agent prompt")

        let (tracker, inbox) = makeTracker()
        inbox.apply(event: "permission", tabID: tab)
        tracker.titleChanged(tabID: tab, title: "⠂ Task", shellPID: 1)
        XCTAssertEqual(inbox.items[tab]?.state, .needsInput, "hook-fed items are left alone")
    }

    func testForgetDropsClosedTab() {
        let (tracker, inbox) = makeTracker()
        let tab = UUID()
        tracker.titleChanged(tabID: tab, title: "⠂ Fix the login bug", shellPID: 1)
        inbox.remove(tabID: tab)
        tracker.forget(tabID: tab)
        XCTAssertNil(tracker.tracked[tab])
    }
}
