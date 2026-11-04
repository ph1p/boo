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
