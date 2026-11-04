import XCTest

@testable import Boo

@MainActor
final class AgentCrewTests: XCTestCase {
    private var inbox: AgentInbox!
    private var crew: AgentCrew!
    private var typed: [(UUID, String)] = []
    private var events: [(String, [String: Any])] = []
    private var open: Set<UUID> = []
    private var scripts: Set<UUID> = []
    private var tasks: [UUID: String] = [:]
    private var orchestrator: UUID?
    private var closed: [UUID] = []

    override func setUp() {
        super.setUp()
        inbox = AgentInbox()
        inbox.locate = { _ in nil }
        crew = AgentCrew()
        typed = []
        events = []
        open = []
        scripts = []
        tasks = [:]
        orchestrator = nil
        closed = []
        crew.closeTab = { [unowned self] in
            closed.append($0)
            open.remove($0)
        }
        crew.state = { [unowned self] in inbox.items[$0]?.state }
        crew.title = { [unowned self] in open.contains($0) ? "tab" : nil }
        crew.taskName = { [unowned self] in tasks[$0] }
        crew.isOrchestrator = { [unowned self] in $0 == orchestrator }
        crew.acceptsTyping = { [unowned self] in inbox.items[$0] != nil && !scripts.contains($0) }
        crew.deliver = { [unowned self] tab, text in
            guard open.contains(tab) else { return false }
            typed.append((tab, text))
            return true
        }
        crew.didDeliver = { [unowned self] tab in inbox.apply(event: "working", tabID: tab) }
        crew.postEvent = { [unowned self] name, payload in events.append((name, payload)) }
        crew.schedule = { work in work() }
        crew.markSeen = { [unowned self] in inbox.markSeen(tabID: $0) }
    }

    private func tab() -> UUID {
        let id = UUID()
        open.insert(id)
        return id
    }

    /// Applies a hook event and lets the crew see the new inbox.
    private func event(_ name: String, _ tab: UUID, message: String? = nil, reply: String? = nil) {
        inbox.apply(event: name, tabID: tab, message: message, reply: reply)
        crew.inboxChanged(inbox.items)
    }

    func testHandlesResolveByNumberHandleParentAndUUID() {
        let parent = tab()
        let child = tab()
        crew.link(child: child, parent: parent, name: "fix-tests")
        XCTAssertEqual(crew.handle(for: parent), "t1")
        XCTAssertEqual(crew.handle(for: child), "t2")
        XCTAssertEqual(crew.resolve("t2", caller: nil), child)
        XCTAssertEqual(crew.resolve("T2", caller: nil), child)
        XCTAssertEqual(crew.resolve("2", caller: nil), child)
        XCTAssertEqual(crew.resolve("parent", caller: child), parent)
        XCTAssertNil(crew.resolve("parent", caller: parent))
        XCTAssertEqual(crew.resolve(parent.uuidString, caller: nil), parent)
        XCTAssertNil(crew.resolve("t9", caller: nil))
        XCTAssertEqual(crew.label(for: child), "t2 fix-tests")
        XCTAssertEqual(crew.children(of: parent), [child])
    }

    func testEnvelope() {
        let text = AgentCrew.envelope([
            .init(from: "t3 docs", state: "done", text: "All good."),
            .init(from: "user", state: nil, text: "hi")
        ])
        XCTAssertEqual(
            text, "<boo from=\"t3 docs\" state=\"done\">\nAll good.\n</boo>\n\n<boo from=\"user\">\nhi\n</boo>")
    }

    func testQueuesWhileWorkingAndDeliversWhenTurnEnds() {
        let target = tab()
        event("working", target)
        XCTAssertEqual(crew.send(to: target, from: nil, text: "also lint"), .queued)
        XCTAssertTrue(typed.isEmpty, "never types into a working agent")
        XCTAssertEqual(crew.outbox[target]?.count, 1)

        event("permission", target, message: "Bash?")
        XCTAssertTrue(typed.isEmpty, "never types into a permission prompt")

        event("stop", target)
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(typed.first?.1, "<boo from=\"user\">\nalso lint\n</boo>")
        XCTAssertNil(crew.outbox[target])
        XCTAssertEqual(inbox.items[target]?.state, .working, "shows as working after delivery")
    }

    func testDeliversRightAwayToIdleAgent() {
        let target = tab()
        event("stop", target)
        XCTAssertEqual(crew.send(to: target, from: nil, text: "next"), .delivered)
        XCTAssertEqual(typed.count, 1)
    }

    func testChildReportsDoneWithItsReplyToParent() {
        let parent = tab()
        let child = tab()
        event("stop", parent)
        crew.link(child: child, parent: parent, name: "docs")
        event("working", child)
        XCTAssertTrue(typed.isEmpty, "working is not reported")
        event("stop", child, reply: "Docs updated.")
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(typed.first?.0, parent)
        XCTAssertEqual(typed.first?.1, "<boo from=\"t2 docs\" state=\"done\">\nDocs updated.\n</boo>")
        XCTAssertFalse(inbox.items[child]?.needsAttention ?? true, "the parent read it; the user doesn't have to")
    }

    /// A session start lists the idle agent with a handle but reports nothing:
    /// it has not finished a turn.
    func testAStartingHelperIsListedButNotReported() {
        let parent = tab()
        let child = tab()
        event("stop", parent)
        crew.link(child: child, parent: parent, name: "docs")
        event("start", child)
        XCTAssertEqual(inbox.items[child]?.state, .done)
        XCTAssertEqual(crew.fields(for: child)["handle"] as? String, "t2")
        XCTAssertTrue(typed.isEmpty)
        event("working", child)
        event("stop", child, reply: "Docs updated.")
        XCTAssertEqual(typed.count, 1, "its first real turn still reports")
    }

    func testChildQuestionIsReportedWithHowToAnswer() {
        let parent = tab()
        let child = tab()
        event("stop", parent)
        crew.link(child: child, parent: parent, name: "docs")
        event("question", child, message: "Which branch?")
        XCTAssertEqual(typed.count, 1)
        XCTAssertTrue(typed[0].1.contains("state=\"needs-input\""))
        XCTAssertTrue(typed[0].1.contains("Which branch?\nAnswer with send_message to t2"))
    }

    func testReportWaitsWhileParentWorks() {
        let parent = tab()
        let child = tab()
        event("working", parent)
        crew.link(child: child, parent: parent, name: "docs")
        event("stop", child, reply: "Done.")
        XCTAssertTrue(typed.isEmpty)
        event("stop", parent)
        XCTAssertEqual(typed.map(\.0), [parent])
    }

    func testChildExitIsReported() {
        let parent = tab()
        let child = tab()
        event("stop", parent)
        crew.link(child: child, parent: parent, name: "docs")
        event("working", child)
        event("end", child)
        XCTAssertEqual(typed.last?.1, "<boo from=\"t2 docs\" state=\"exited\">\nThe agent exited.\n</boo>")
    }

    func testOrchestratorGetsAnEventInsteadOfTyping() {
        let parent = tab()
        orchestrator = parent
        let child = tab()
        crew.link(child: child, parent: parent, name: "docs")
        event("stop", child, reply: "Done.")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(events.first?.0, "agent_message")
        XCTAssertEqual(events.first?.1["from"] as? String, "t2 docs")
        XCTAssertEqual(events.first?.1["state"] as? String, "done")
    }

    func testScriptsAreNeverTypedIntoAndReadTheirInbox() {
        let script = tab()
        scripts.insert(script)
        event("stop", script)
        XCTAssertEqual(crew.send(to: script, from: nil, text: "hello"), .queued)
        XCTAssertTrue(typed.isEmpty)
        let reply = crew.handleSocketCommand(cmd: "agent_messages", json: [:], caller: script)
        let messages = reply?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["text"] as? String, "hello")
        XCTAssertNil(crew.outbox[script], "reading clears the inbox")
    }

    func testShellTabsWithoutAgentAreNeverTypedInto() {
        let shell = tab()
        XCTAssertEqual(crew.send(to: shell, from: nil, text: "rm -rf /"), .queued)
        XCTAssertTrue(typed.isEmpty)
    }

    func testAgentSendRefusals() {
        let caller = tab()
        let other = tab()
        func send(_ json: [String: Any]) -> String? {
            crew.handleSocketCommand(cmd: "agent_send", json: json, caller: caller)?["error"] as? String
        }
        XCTAssertEqual(send(["tab_id": caller.uuidString, "text": "x"]), "that is your own tab")
        XCTAssertEqual(send(["tab_id": other.uuidString, "text": "  "]), "text is empty")
        XCTAssertNotNil(send(["tab_id": UUID().uuidString, "text": "x"]), "closed tab")
        XCTAssertNotNil(send(["text": "x"]), "missing target")
        let ok = crew.handleSocketCommand(
            cmd: "agent_send", json: ["tab_id": other.uuidString, "text": "x"], caller: caller)
        XCTAssertEqual(ok?["ok"] as? Bool, true)
        XCTAssertEqual(ok?["status"] as? String, "queued")
        XCTAssertNil(crew.handleSocketCommand(cmd: "agent_inbox", json: [:], caller: caller))
    }

    func testMessagesBetweenTwoAgentsAreCapped() {
        let a = tab()
        let b = tab()
        var clock = Date(timeIntervalSince1970: 0)
        crew.now = { clock }
        func send(_ from: UUID, _ to: UUID) -> Bool {
            crew.handleSocketCommand(cmd: "agent_send", json: ["tab_id": to.uuidString, "text": "x"], caller: from)?[
                "ok"]
                as? Bool == true
        }
        for i in 0..<AgentCrew.maxMessages {
            XCTAssertTrue(send(i.isMultiple(of: 2) ? a : b, i.isMultiple(of: 2) ? b : a))
        }
        XCTAssertFalse(send(a, b), "both directions count toward one limit")
        XCTAssertTrue(send(a, tab()), "other pairs are not affected")
        XCTAssertEqual(crew.send(to: b, from: nil, text: "from the user"), .queued, "the user is never capped")
        clock = clock.addingTimeInterval(AgentCrew.messageWindow + 1)
        XCTAssertTrue(send(a, b), "the limit resets after the window")
    }

    func testHelpersCloseWithTheTabThatStartedThem() {
        let parent = tab()
        let helper = tab()
        let other = tab()
        crew.link(child: helper, parent: parent, name: "docs")
        event("working", parent)
        event("working", helper)
        open.remove(parent)
        crew.tabClosed(parent)
        XCTAssertEqual(closed, [helper])
        XCTAssertFalse(closed.contains(other))
        XCTAssertNil(crew.links[helper])
        event("end", helper)
        XCTAssertTrue(typed.isEmpty, "no exit report to a closed parent")
    }

    func testHelpersCloseWhenTheParentAgentLeavesTheInbox() {
        let parent = tab()
        let helper = tab()
        crew.link(child: helper, parent: parent, name: "docs")
        event("working", parent)
        open.remove(parent)
        event("end", parent)
        XCTAssertEqual(closed, [helper])
    }

    func testHelpersStayWhenTheParentAgentExitsButItsTabStays() {
        let parent = tab()
        let helper = tab()
        crew.link(child: helper, parent: parent, name: "docs")
        event("working", parent)
        event("end", parent)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertNotNil(crew.links[helper])
    }

    func testLongReportsAreTruncated() {
        let long = String(repeating: "a", count: AgentCrew.maxReportLength + 10)
        let trimmed = AgentCrew.trimmed(long)
        XCTAssertTrue(trimmed.hasPrefix(String(repeating: "a", count: AgentCrew.maxReportLength)))
        XCTAssertTrue(trimmed.hasSuffix("read_pane shows the rest)"))
    }

    func testNamesDropStatusGlyphs() {
        XCTAssertEqual(AgentCrew.displayName("✳ Boo hi4 handle"), "Boo hi4 handle")
        XCTAssertEqual(AgentCrew.displayName("⠋ 2nd pass"), "2nd pass")
        XCTAssertEqual(AgentCrew.displayName("docs"), "docs")
    }

    func testWaitCollectedReportIsNotTypedAgain() {
        let parent = tab()
        let child = tab()
        crew.link(child: child, parent: parent, name: "poem")
        event("prompt", parent)  // the parent runs `boo wait`
        event("working", child)
        event("stop", child, reply: "Owls.")
        crew.send(to: parent, from: child, text: "also: a note")
        XCTAssertEqual(crew.outbox[parent]?.count, 2)
        let reply = crew.handleSocketCommand(
            cmd: "agent_collected", json: ["tab_id": child.uuidString], caller: parent)
        XCTAssertEqual(reply?["dropped"] as? Int, 1)
        XCTAssertFalse(inbox.items[child]?.needsAttention ?? true, "collected answers don't wait for the user")
        event("stop", parent)
        XCTAssertEqual(
            typed.map(\.1), ["<boo from=\"t2 poem\">\nalso: a note\n</boo>"], "only the message sent on purpose")
    }

    func testHelperNamesAreTheFirstSentenceCutAtAWord() {
        XCTAssertEqual(
            AgentCrew.shortName("Write a two-line poem about owls. Reply with only the poem."),
            "Write a two-line poem about owls")
        XCTAssertEqual(
            AgentCrew.shortName("Fix the bug in add() in calc.py. Commit it."), "Fix the bug in add() in calc.py")
        XCTAssertEqual(AgentWorktree.slug("Fix the bug in add() in calc.py"), "fix-the-bug-in-add-in-calc-py")
        XCTAssertEqual(
            AgentCrew.shortName("Write a long letter to every owl in the forest about the night"),
            "Write a long letter to every owl in the…")
        XCTAssertEqual(AgentCrew.shortName("Review AgentCrew.swift\nthen the tests"), "Review AgentCrew.swift")
        XCTAssertEqual(AgentCrew.shortName(String(repeating: "x", count: 50)), String(repeating: "x", count: 40) + "…")
    }

    /// A task started from the New Task dialog has no parent link; the crew
    /// still calls it what its workspace is called, not what Claude titles its tab.
    /// A plain shell that sends a message reads "shell", not its last command.
    func testNamesFollowTheTaskWorkspaceAndShellsReadShell() {
        let task = UUID()
        let shell = UUID()
        let agent = UUID()
        open = [task, shell, agent]
        inbox.apply(event: "working", tabID: task)
        inbox.apply(event: "working", tabID: agent)
        tasks[task] = "Add a.txt"
        XCTAssertEqual(crew.name(for: task), "Add a.txt")
        XCTAssertEqual(crew.name(for: shell), "shell")
        XCTAssertEqual(crew.name(for: agent), "tab")
        crew.link(child: agent, parent: task, name: "reviewer")
        XCTAssertEqual(crew.name(for: agent), "reviewer")
        XCTAssertEqual(crew.label(for: shell), "t\(crew.handles[shell]!) shell")
    }

    /// After a restart the task workspace is back but its agent is not: it is
    /// listed as stopped, under its workspace name, until reviewed or removed.
    func testTaskWorkspacesWithoutALiveAgentListAsStopped() {
        let task = Workspace(folderPath: "/w/add-a")
        task.customName = "Add a.txt"
        let running = Workspace(folderPath: "/w/add-b")
        let plain = Workspace(folderPath: "/src/app")
        let liveTab = running.panes.values.first!.tabs[0].id
        let rows = AgentsPlugin.stoppedTaskRows(
            workspaces: [task, running, plain], live: [liveTab], isTask: { $0.hasPrefix("/w/") })
        XCTAssertEqual(rows.map(\.name), ["Add a.txt"])
        XCTAssertEqual(rows.first?.id, task.panes.values.first!.tabs[0].id)
        XCTAssertEqual(rows.first?.isStopped, true)
        XCTAssertEqual(rows.first?.isTask, true)
    }

    func testSidebarRowsListHelpersUnderTheirParentWithAPlainDetail() {
        let parent = tab()
        let child = tab()
        crew.link(child: child, parent: parent, name: "fix")
        event("working", parent)
        event("working", child)
        event("stop", child, reply: "Fixed. `add` in `calc.py`.\nDetails follow.")
        let rows = AgentsPlugin.crewRows(
            items: Array(inbox.items.values), crew: crew, isTask: { _ in false }, isReachable: { _ in true })
        XCTAssertEqual(rows.map(\.handle), ["t1", "t2"])
        XCTAssertEqual(rows.last?.parent, "t1")
        XCTAssertEqual(rows.last?.detail, "Fixed. add in calc.py.")
        // A tab in no Boo window has no title: its folder tells it apart.
        let outside = UUID()
        inbox.apply(event: "working", tabID: outside, cwd: "/src/api")
        let outsideRow = AgentsPlugin.crewRows(
            items: Array(inbox.items.values), crew: crew, isTask: { _ in false }, isReachable: { _ in false }
        ).first { $0.id == outside }
        XCTAssertEqual(outsideRow?.name, "claude in api")
    }

    func testCrewListArrowKeysStopAtTheEnds() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(
            AgentCrewUIState.adjacent(to: nil, offset: 1, in: ids), ids[0], "↓ with nothing selected picks the first")
        XCTAssertEqual(AgentCrewUIState.adjacent(to: nil, offset: -1, in: ids), ids[2], "↑ picks the last")
        XCTAssertEqual(AgentCrewUIState.adjacent(to: ids[0], offset: 1, in: ids), ids[1])
        XCTAssertEqual(AgentCrewUIState.adjacent(to: ids[2], offset: 1, in: ids), ids[2])
        XCTAssertEqual(AgentCrewUIState.adjacent(to: ids[0], offset: -1, in: ids), ids[0])
        XCTAssertEqual(AgentCrewUIState.adjacent(to: UUID(), offset: 1, in: ids), ids[0], "a row that left starts over")
        XCTAssertNil(AgentCrewUIState.adjacent(to: nil, offset: 1, in: []))
    }

    @MainActor
    func testInlineFieldOpensOnItsRowAndClosesClean() {
        let ui = AgentCrewUIState()
        let id = UUID()
        ui.open(.message(id))
        XCTAssertEqual(ui.selection, id, "messaging an agent selects its row")
        ui.text = "hi"
        ui.note = "error"
        ui.open(.newTask)
        XCTAssertEqual(ui.text, "", "a new field starts empty")
        XCTAssertNil(ui.note)
        ui.isBusy = true
        ui.close()
        XCTAssertNil(ui.composer)
        XCTAssertFalse(ui.isBusy)
        XCTAssertEqual(ui.selection, id, "closing keeps the selection")
    }
}
