import Cocoa
import XCTest

@testable import Boo

@MainActor
final class AgentIntegrationTests: XCTestCase {
    // MARK: Codex notify

    func testCodexNotifyIsAddedToAnEmptyConfig() {
        let merged = BooPaths.mergingCodexNotify(hook: "/h/boo-claude-hook", into: "")
        XCTAssertEqual(
            merged, "# Boo agent inbox: reports when a Codex turn ends.\nnotify = [\"/h/boo-claude-hook\", \"codex\"]\n"
        )
    }

    func testCodexNotifyGoesAboveTheFirstTable() throws {
        let config = "model = \"o3\"\n\n[mcp_servers.x]\ncommand = \"x\"\n"
        let merged = try XCTUnwrap(BooPaths.mergingCodexNotify(hook: "/h", into: config))
        XCTAssertTrue(merged.hasSuffix(config))
        XCTAssertTrue(merged.contains("notify = [\"/h\", \"codex\"]"))
    }

    func testCodexNotifyKeepsTheUsersOwnProgram() {
        let config = "notify = [\"other\"]\n[x]\n"
        XCTAssertNil(BooPaths.mergingCodexNotify(hook: "/h", into: config))
    }

    func testCodexNotifyInsideATableIsNotTopLevel() {
        let config = "[tui]\nnotify = true\n"
        XCTAssertNotNil(BooPaths.mergingCodexNotify(hook: "/h", into: config))
    }

    // MARK: Composer drafts

    func testClosingKeepsTheDraftForTheNextOpen() {
        let ui = AgentCrewUIState()
        let id = UUID()
        ui.open(.message(id))
        ui.text = "half a thought"
        ui.close()
        XCTAssertEqual(ui.text, "")
        ui.open(.message(id))
        XCTAssertEqual(ui.text, "half a thought")
    }

    func testDraftsAreKeptPerComposer() {
        let ui = AgentCrewUIState()
        let a = UUID()
        let b = UUID()
        ui.open(.message(a))
        ui.text = "for a"
        ui.open(.message(b))
        XCTAssertEqual(ui.text, "")
        ui.text = "for b"
        ui.close()
        ui.open(.message(a))
        XCTAssertEqual(ui.text, "for a")
        ui.open(.message(b))
        XCTAssertEqual(ui.text, "for b")
    }

    func testCancelDropsTheDraft() {
        let ui = AgentCrewUIState()
        let id = UUID()
        ui.open(.message(id))
        ui.text = "never mind"
        ui.cancel()
        ui.open(.message(id))
        XCTAssertEqual(ui.text, "")
    }

    func testBlankTextLeavesNoDraft() {
        let ui = AgentCrewUIState()
        let id = UUID()
        ui.open(.message(id))
        ui.text = "  \n"
        ui.close()
        XCTAssertTrue(ui.drafts.isEmpty)
    }

    // MARK: Palette

    func testNoAgentRowsWhileAgentsAreOff() {
        let settings = AppSettings.shared
        let was = settings.agentsEnabled
        defer { settings.agentsEnabled = was }
        settings.agentsEnabled = false
        XCTAssertTrue(PaletteSources.agents().isEmpty)
        XCTAssertTrue(AgentMenuItems.newTabItems(paneID: UUID()).isEmpty)
        XCTAssertTrue(AgentMenuItems.tabItems(tabID: UUID(), paneID: UUID()).isEmpty)
    }
}
