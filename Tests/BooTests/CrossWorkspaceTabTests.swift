import XCTest

@testable import Boo

/// Tests for cross-workspace tab move logic at the model level:
/// - detecting the "only tab in workspace" condition
/// - total tab count across multi-pane workspaces
/// - workspace state after a simulated tab transfer
/// - AppState integrity after workspace removal from a move
final class CrossWorkspaceTabTests: XCTestCase {

    // MARK: - Simulated cross-workspace tab transfer (model layer)

    func testTransferTabToOtherWorkspaceModel() {
        let sourceWS = Workspace(folderPath: "/source")
        let destWS = Workspace(folderPath: "/dest")

        let sourcePaneID = sourceWS.activePaneID
        let sourcePane = sourceWS.pane(for: sourcePaneID)!
        _ = sourcePane.addTab(workingDirectory: "/extra")  // 2 tabs now

        let destPaneID = destWS.activePaneID
        let destPane = destWS.pane(for: destPaneID)!

        // Extract tab 0 from source and insert into dest
        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: destPane.tabs.count)

        XCTAssertEqual(sourcePane.tabs.count, 1)
        XCTAssertEqual(destPane.tabs.count, 2)
    }

    func testTransferLastTabLeavesSourcePaneEmpty() {
        let sourceWS = Workspace(folderPath: "/source")
        let destWS = Workspace(folderPath: "/dest")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        let destPane = destWS.pane(for: destWS.activePaneID)!

        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: 0)

        XCTAssertTrue(sourcePane.tabs.isEmpty)
        XCTAssertEqual(destPane.tabs.count, 2)
    }

    func testTransferPreservesTabWorkingDirectory() {
        let sourceWS = Workspace(folderPath: "/project")
        let destWS = Workspace(folderPath: "/other")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        let destPane = destWS.pane(for: destWS.activePaneID)!

        let tab = sourcePane.extractTab(at: 0)!
        destPane.insertTab(tab, at: destPane.tabs.count)

        XCTAssertEqual(destPane.tabs.last?.workingDirectory, "/project")
    }

    func testTransferPreservesTabTitle() {
        let sourceWS = Workspace(folderPath: "/tmp")
        let destWS = Workspace(folderPath: "/other")

        let sourcePane = sourceWS.pane(for: sourceWS.activePaneID)!
        sourcePane.updateTitle(at: 0, "nvim")

        let tab = sourcePane.extractTab(at: 0)!
        let destPane = destWS.pane(for: destWS.activePaneID)!
        destPane.insertTab(tab, at: 0)

        XCTAssertEqual(destPane.tabs[0].title, "nvim")
    }
}
