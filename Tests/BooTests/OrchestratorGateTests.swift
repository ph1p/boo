import XCTest

@testable import Boo

@MainActor
final class OrchestratorGateTests: XCTestCase {
    private let callerTab = UUID()
    private let agentTab = UUID()

    private var full: CapabilityTokens.Caller { .init(tabID: callerTab, grade: .full) }
    private var gated: CapabilityTokens.Caller { .init(tabID: callerTab, grade: .gated) }

    private func target(agent: Bool = false, remote: Bool = false) -> OrchestratorGate.Target {
        .init(tabIDs: [agentTab], isAgent: agent, isRemote: remote)
    }

    private func decide(
        _ cmd: String, _ caller: CapabilityTokens.Caller?, _ target: OrchestratorGate.Target?,
        owned: Bool = false, granted: Bool = false
    ) -> OrchestratorGate.Decision {
        OrchestratorGate.decide(
            cmd: cmd, caller: caller, target: target, owns: { _ in owned }, granted: { _ in granted })
    }

    private func isReject(_ decision: OrchestratorGate.Decision) -> Bool {
        if case .reject = decision { return true }
        return false
    }

    func testSensitiveCommands() {
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "agent_respond", target: nil))
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "merge_task", target: nil))
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "discard_task", target: target()))
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "send_text", target: target(agent: true)))
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "send_key", target: target(remote: true)))
        XCTAssertTrue(OrchestratorGate.isSensitive(cmd: "close_pane", target: target(agent: true)))
        XCTAssertFalse(OrchestratorGate.isSensitive(cmd: "close_pane", target: target(remote: true)))
        XCTAssertFalse(OrchestratorGate.isSensitive(cmd: "send_text", target: target()), "local shell pane")
        XCTAssertFalse(OrchestratorGate.isSensitive(cmd: "get_screen", target: target(agent: true)))
        XCTAssertFalse(OrchestratorGate.isSensitive(cmd: "split_pane", target: nil))
    }

    func testTokenlessReadsWorkAndSensitiveCommandsAreRejected() {
        XCTAssertEqual(decide("get_layout", nil, nil), .allow)
        XCTAssertEqual(decide("send_text", nil, target()), .allow, "local pane needs no token")
        XCTAssertTrue(isReject(decide("agent_respond", nil, target(agent: true))))
        XCTAssertTrue(isReject(decide("send_text", nil, target(agent: true))))
        XCTAssertTrue(isReject(decide("send_key", nil, target(remote: true))))
        XCTAssertTrue(isReject(decide("close_pane", nil, target(agent: true))))
        XCTAssertTrue(isReject(decide("merge_task", nil, target())))
    }

    func testFullTokenRunsEverything() {
        for cmd in ["agent_respond", "send_text", "send_key", "close_pane", "merge_task", "discard_task"] {
            XCTAssertEqual(decide(cmd, full, target(agent: true, remote: true)), .allow, cmd)
        }
    }

    func testGatedTokenNeedsApprovalUnlessOwnedOrGranted() {
        for cmd in ["agent_respond", "send_text", "send_key", "close_pane"] {
            XCTAssertEqual(decide(cmd, gated, target(agent: true)), .approve, cmd)
            XCTAssertEqual(decide(cmd, gated, target(agent: true), owned: true), .allow, "\(cmd) owned")
            XCTAssertEqual(decide(cmd, gated, target(agent: true), granted: true), .allow, "\(cmd) granted")
        }
        XCTAssertEqual(decide("send_text", gated, target(remote: true)), .approve)
        XCTAssertEqual(decide("send_text", gated, target()), .allow, "local shell pane")
        XCTAssertEqual(decide("get_screen", gated, target(agent: true)), .allow, "reads are free")
    }

    func testMergeAndDiscardAlwaysNeedApproval() {
        for cmd in ["merge_task", "discard_task"] {
            XCTAssertEqual(decide(cmd, gated, target(), owned: true), .approve, cmd)
            XCTAssertEqual(decide(cmd, gated, target(), owned: true, granted: true), .approve, cmd)
            XCTAssertEqual(decide(cmd, gated, nil), .approve, "\(cmd) with unresolved target")
        }
    }

    func testPaneWithMixedTabsNeedsEveryTabOwned() {
        let other = UUID()
        let mixed = OrchestratorGate.Target(tabIDs: [agentTab, other], isAgent: true, isRemote: false)
        let owned = agentTab
        let decision = OrchestratorGate.decide(
            cmd: "close_pane", caller: gated, target: mixed, owns: { $0 == owned }, granted: { _ in false })
        XCTAssertEqual(decision, .approve)
    }

    func testTokensResolveToTabAndGrade() {
        let tokens = CapabilityTokens()
        let tab = UUID()
        let token = tokens.token(for: tab)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(tokens.token(for: tab), token, "stable per tab")
        XCTAssertNotEqual(tokens.token(for: UUID()), token)
        XCTAssertEqual(tokens.resolve(token), .init(tabID: tab, grade: .full))
        tokens.setGrade(.gated, for: tab)
        XCTAssertEqual(tokens.resolve(token)?.grade, .gated)
        XCTAssertNil(tokens.resolve("nope"))
        XCTAssertNil(tokens.resolve(nil))

        let task = UUID()
        tokens.markOwned(task, by: tab)
        XCTAssertTrue(tokens.owns(tab, task))
        tokens.disown(task)
        XCTAssertFalse(tokens.owns(tab, task))

        tokens.revoke(tabID: tab)
        XCTAssertNil(tokens.resolve(token))
    }
}
