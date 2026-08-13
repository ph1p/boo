import Cocoa
import XCTest

@testable import Boo

/// Minimal ContentViewProtocol stand-in so the cross-pane transfer path can be exercised
/// without a real editor/browser (and without a GhosttyView, which needs a live surface).
private final class StubContentView: NSView, ContentViewProtocol {
    let contentType: ContentType
    let marker: String

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    private(set) var isCleanedUp = false
    private(set) var activateCount = 0

    init(contentType: ContentType, marker: String) {
        self.contentType = contentType
        self.marker = marker
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// State round-tripping is irrelevant here — these tests assert view *identity* across a
    /// cross-pane transfer, so hand back the state the caller last restored (or a placeholder).
    var stateToSave: ContentState = .terminal(TerminalContentState())

    func activate() { activateCount += 1 }
    func deactivate() {}
    func cleanup() { isCleanedUp = true }
    func saveState() -> ContentState { stateToSave }
    func restoreState(_ state: ContentState) { stateToSave = state }
}

/// Regression coverage for tab content being lost when a tab is dragged between panes.
///
/// `moveTabBetweenPanes` inserts the incoming tab (which shifts `activeTabIndex`) *before*
/// calling `forceActivateTab`, so by the time `storeCurrentView` runs, `pane.activeTab` names
/// the incoming tab while the still-displayed view belongs to the destination's previous tab.
/// Caching the old view under the incoming tab's id overwrote the transferred view and the
/// dragged tab rendered the wrong content.
@MainActor final class CrossPaneTabTransferTests: XCTestCase {

    /// Build a detached editor tab via the pane model, then lift it out so it can be inserted
    /// wherever a test needs it (mirroring what a drag does).
    private func makeEditorTab(title: String) -> Pane.Tab {
        let scratch = Pane()
        let index = scratch.addTab(contentType: .editor, workingDirectory: "/tmp", title: title)
        return scratch.extractTab(at: index)!
    }

    /// The exact drop ordering from `moveTabBetweenPanes`: insertTab → insertContentView →
    /// forceActivateTab. The transferred view must be the one displayed afterwards.
    func testDroppedTabKeepsItsOwnContentView() {
        let destPane = Pane()
        let dest = PaneView(paneID: UUID(), pane: destPane)

        // Destination already shows an editor tab of the SAME content type — the case the
        // old `cv.contentType == tab.contentType` guard failed to catch.
        let existingTab = makeEditorTab(title: "existing")
        destPane.insertTab(existingTab, at: 0)
        let existingView = StubContentView(contentType: .editor, marker: "existing")
        dest.insertContentView(existingView, for: existingTab.id)
        dest.forceActivateTab(0)
        XCTAssertIdentical(dest.activeContentView, existingView, "precondition: existing tab displayed")

        // Now perform the drop.
        let incomingTab = makeEditorTab(title: "incoming")
        let incomingView = StubContentView(contentType: .editor, marker: "incoming")
        destPane.insertTab(incomingTab, at: 1)
        dest.insertContentView(incomingView, for: incomingTab.id)
        dest.forceActivateTab(1)

        XCTAssertIdentical(
            dest.activeContentView, incomingView,
            "the dropped tab must display the view that came with it, not the destination's previous view")
        XCTAssertFalse(incomingView.isCleanedUp, "the transferred view must not be torn down")
    }

    /// The displaced view must survive in the cache so switching back still works.
    func testPreviousTabViewSurvivesTheDropAndIsRestored() {
        let destPane = Pane()
        let dest = PaneView(paneID: UUID(), pane: destPane)

        let existingTab = makeEditorTab(title: "existing")
        destPane.insertTab(existingTab, at: 0)
        let existingView = StubContentView(contentType: .editor, marker: "existing")
        dest.insertContentView(existingView, for: existingTab.id)
        dest.forceActivateTab(0)

        let incomingTab = makeEditorTab(title: "incoming")
        let incomingView = StubContentView(contentType: .editor, marker: "incoming")
        destPane.insertTab(incomingTab, at: 1)
        dest.insertContentView(incomingView, for: incomingTab.id)
        dest.forceActivateTab(1)

        XCTAssertFalse(existingView.isCleanedUp, "the displaced view must be cached, not destroyed")

        // Switch back to the original tab — it must get its own view again.
        let existingIndex = destPane.tabs.firstIndex(where: { $0.id == existingTab.id })!
        dest.activateTab(existingIndex)
        XCTAssertIdentical(
            dest.activeContentView, existingView,
            "switching back must restore the original tab's own view")
    }

    /// Extracting the displayed view for a drag must not leave the source pane still claiming
    /// it; a later view store in the source must not re-cache a view it handed away.
    func testExtractedViewIsNotReCachedBySource() {
        let sourcePane = Pane()
        let source = PaneView(paneID: UUID(), pane: sourcePane)

        let keptTab = makeEditorTab(title: "kept")
        let draggedTab = makeEditorTab(title: "dragged")
        sourcePane.insertTab(keptTab, at: 0)
        sourcePane.insertTab(draggedTab, at: 1)

        let keptView = StubContentView(contentType: .editor, marker: "kept")
        source.insertContentView(keptView, for: keptTab.id)
        let draggedView = StubContentView(contentType: .editor, marker: "dragged")
        source.insertContentView(draggedView, for: draggedTab.id)
        source.forceActivateTab(1)
        XCTAssertIdentical(source.activeContentView, draggedView, "precondition: dragged tab displayed")

        // Drag start: extractTab shifts activeTabIndex, then the view is handed over.
        let draggedIndex = sourcePane.tabs.firstIndex(where: { $0.id == draggedTab.id })!
        _ = sourcePane.extractTab(at: draggedIndex)
        let extracted = source.extractContentView(for: draggedTab.id)
        XCTAssertIdentical(extracted, draggedView, "the dragged tab's own view must be handed over")

        // Source re-displays whatever remains; the handed-away view must not come back.
        source.startActiveSession()
        XCTAssertIdentical(
            source.activeContentView, keptView,
            "source must fall back to its remaining tab's view")
        XCTAssertNotIdentical(
            source.activeContentView, draggedView,
            "source must not re-adopt a view it already transferred away")
    }
}
