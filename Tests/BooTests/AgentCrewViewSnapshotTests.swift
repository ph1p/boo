import SwiftUI
import XCTest

@testable import Boo

/// Renders the crew sidebar with a typical crew. Set `BOO_SNAPSHOT_DIR` to
/// write `agent-crew.png` there for a visual check.
@MainActor
final class AgentCrewViewSnapshotTests: XCTestCase {
    private func row(
        _ handle: String, _ name: String, _ state: AgentInbox.State, detail: String? = nil,
        parent: String? = nil, queued: Int = 0, attention: Bool = false, task: Bool = false
    ) -> AgentCrewRow {
        AgentCrewRow(
            id: UUID(), handle: handle, name: name, agent: "claude", state: state, detail: detail,
            parent: parent, queued: queued, needsAttention: attention, isTask: task)
    }

    func testRendersGroupsAndLinks() throws {
        let rows = [
            row("t1", "main", .working, detail: "using Bash"),
            row(
                "t2", "fix-tests", .needsInput, detail: "Allow Bash: pnpm test?", parent: "t1", attention: true,
                task: true),
            row("t3", "docs", .working, detail: "using Edit", parent: "t1", queued: 1, task: true),
            row("t4", "review", .done, detail: "Looks good; two nits in AgentCrew.swift.", parent: "t1"),
            row("t5", "api", .error, detail: "Stopped with an error.", attention: true),
            AgentCrewRow(
                id: UUID(), handle: "t6", name: "", agent: "claude", state: .done, detail: "Done.", parent: nil,
                queued: 0, needsAttention: false, isTask: false, isReachable: false)
        ]
        let view = AgentCrewView(
            rows: rows, fontScale: SidebarFontScale(base: 13, fontName: ""),
            textColor: .white, mutedColor: Color(white: 0.6), accentColor: .blue,
            onJump: { _ in }, onReview: { _ in }, onMerge: { _ in },
            onDiscard: { _ in }
        )
        .frame(width: 260)
        .background(Color(white: 0.12))

        let image = try render(view, as: "agent-crew.png")
        XCTAssertGreaterThan(image.size.height, 150, "three groups, five rows and the new-agent button")
    }

    /// No agents yet, the new-agent form open: agent and place pickers, then the prompt.
    func testRendersNewAgentForm() throws {
        let ui = AgentCrewUIState.shared
        ui.open(.newTask)
        defer { ui.close() }
        let view = AgentCrewView(
            rows: [], fontScale: SidebarFontScale(base: 13, fontName: ""),
            textColor: .white, mutedColor: Color(white: 0.6), accentColor: .blue,
            onJump: { _ in }, onReview: { _ in }, onMerge: { _ in }, onDiscard: { _ in },
            agents: [.claudeCode, .codex, .openCode]
        )
        .frame(width: 260)
        .background(Color(white: 0.12))
        let image = try render(view, as: "agent-crew-new.png")
        XCTAssertGreaterThan(image.size.height, 80, "the empty line, two pickers and the prompt")
    }

    private func workspace(_ name: String, order: Int, color: NSColor? = nil, task: Bool = false) -> CrewWorkspace {
        CrewWorkspace(id: UUID(), name: name, isTask: task, order: order, color: color)
    }

    private func crew(
        _ rows: [AgentCrewRow], active: CrewWorkspace? = nil, activeOnly: Bool = false,
        agents: [AgentKind] = [.claudeCode]
    ) -> some View {
        AgentCrewView(
            rows: rows, fontScale: SidebarFontScale(base: 13, fontName: ""),
            textColor: .white, mutedColor: Color(white: 0.6), accentColor: .blue,
            onJump: { _ in }, onReview: { _ in }, onMerge: { _ in }, onDiscard: { _ in },
            agents: agents, activeWorkspaceID: active?.id, activeWorkspaceName: active?.name,
            activeOnly: activeOnly
        )
        .frame(width: 260)
        .background(Color(white: 0.12))
    }

    private func placed(_ row: AgentCrewRow, in workspace: CrewWorkspace?) -> AgentCrewRow {
        var row = row
        row.workspace = workspace
        return row
    }

    /// Three workspaces and agents outside Boo: the active one first, a folded one.
    func testRendersWorkspaceGroups() throws {
        let boo = workspace("boo", order: 1, color: .systemTeal)
        let api = workspace("api", order: 0, color: .systemPink)
        let fix = workspace("fix-tests", order: 2, color: .systemTeal, task: true)
        let site = workspace("site", order: 3)
        let rows = [
            placed(row("t1", "main", .working, detail: "using Bash"), in: boo),
            placed(row("t3", "docs", .working, detail: "using Edit", parent: "t1", queued: 1), in: boo),
            placed(
                row(
                    "t2", "fix-tests", .needsInput, detail: "Allow Bash: pnpm test?", parent: "t1", attention: true,
                    task: true), in: fix),
            placed(row("t5", "api", .error, detail: "Stopped with an error.", attention: true), in: api),
            placed(row("t6", "landing", .needsInput, detail: "Which font?", attention: true), in: site),
            AgentCrewRow(
                id: UUID(), handle: "t7", name: "claude in scripts", agent: "claude", state: .done, detail: "Done.",
                parent: nil, queued: 0, needsAttention: false, isTask: false, isReachable: false)
        ]
        let ui = AgentCrewUIState.shared
        ui.collapsedGroups = [site.id.uuidString]
        defer { ui.collapsedGroups = [] }
        let image = try render(crew(rows, active: boo), as: "agent-crew-grouped.png")
        XCTAssertGreaterThan(image.size.height, 200)
    }

    /// Only the active workspace; a footer counts the others and who needs you.
    func testRendersActiveWorkspaceOnly() throws {
        let boo = workspace("boo", order: 0, color: .systemTeal)
        let api = workspace("api", order: 1, color: .systemPink)
        let rows = [
            placed(row("t1", "main", .working, detail: "using Bash"), in: boo),
            placed(row("t2", "review", .done, detail: "Looks good; two nits."), in: boo),
            placed(row("t5", "api", .needsInput, detail: "Allow Bash?", attention: true), in: api),
            placed(row("t6", "api-docs", .working), in: api),
            placed(row("t8", "scratch", .working), in: nil)
        ]
        let image = try render(crew(rows, active: boo, activeOnly: true), as: "agent-crew-strict.png")
        XCTAssertGreaterThan(image.size.height, 100)
    }

    /// Agents found by their process only: no handle, no message action.
    func testRendersAgentsWithoutHooks() throws {
        let boo = workspace("boo", order: 0, color: .systemOrange)
        var codex = placed(row("", "codex in boo", .working, detail: nil), in: boo)
        codex.hasHooks = false
        codex.folder = "/src/boo"
        let image = try render(
            crew([placed(row("t1", "main", .working, detail: "using Bash"), in: boo), codex], active: boo),
            as: "agent-crew-hookless.png")
        XCTAssertGreaterThan(image.size.height, 80)
    }

    func testRendersEmptyState() throws {
        let boo = workspace("boo", order: 0)
        let image = try render(crew([], active: boo, agents: [.claudeCode, .codex]), as: "agent-crew-empty.png")
        XCTAssertGreaterThan(image.size.height, 100, "icon, title, line and button")
    }

    /// The header "+" popover's content.
    func testRendersNewAgentPopoverForm() throws {
        let ui = AgentCrewUIState.shared
        let place = ui.taskPlace
        ui.taskPlace = .worktree
        ui.note = "Not a git repository: /src/scratch"
        ui.noteIsWarning = true
        defer {
            ui.taskPlace = place
            ui.close()
        }
        let tokens = Tokens(theme: .defaultDark)
        let form = AgentNewTaskForm(
            agents: [.claudeCode, .codex, .openCode], workspaceName: "boo", onStartHere: { _, _ in },
            onStartTask: { _, _, _ in }, onDone: {}
        )
        .frame(width: 288)
        .environment(\.tokens, tokens)
        .background(tokens.cardBg)
        let image = try render(form, as: "agent-crew-new-popover.png")
        XCTAssertGreaterThan(image.size.height, 120)
    }

    private func render(_ view: some View, as name: String) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"],
            let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return image
    }
}
