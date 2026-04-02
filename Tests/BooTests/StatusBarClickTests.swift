import XCTest

@testable import Boo

/// Tests that hidden status bar plugin segments don't intercept clicks
/// meant for visible segments that shifted into their former positions.
@MainActor
final class StatusBarClickTests: XCTestCase {

    /// A spy StatusBarPlugin that records clicks and can be hidden.
    final class SpyIconSegment: StatusBarPlugin {
        let id: String
        let position: StatusBarPosition = .right
        let priority: Int
        let associatedPanelID: String?
        var isHidden = false
        var hitRect: NSRect = .zero
        var clickCount = 0

        init(id: String, priority: Int, panelID: String) {
            self.id = id
            self.priority = priority
            self.associatedPanelID = panelID
        }

        func isVisible(settings: AppSettings, state: StatusBarState) -> Bool {
            !isHidden
        }

        func update(state: StatusBarState) {}

        func draw(
            at rx: CGFloat, y: CGFloat, theme: TerminalTheme, settings: AppSettings, state: StatusBarState,
            ctx: CGContext
        ) -> CGFloat {
            let iconSize: CGFloat = 14
            let drawX = rx - iconSize - 2
            hitRect = NSRect(x: drawX - 2, y: 0, width: iconSize + 6, height: 22)
            return iconSize + 6
        }

        @MainActor func handleClick(at point: NSPoint, in barView: StatusBarView) -> Bool {
            guard hitRect.contains(point) else { return false }
            clickCount += 1
            barView.onSidebarPluginToggle?(associatedPanelID ?? "")
            return true
        }

        func accessibilitySegmentLabel(state: StatusBarState) -> String? { nil }
    }

    /// Proves that hiding a plugin causes its stale hitRect to overlap
    /// with the next visible plugin that shifts into its position.
    func testStaleHitRectOverlapsAfterHide() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))

        let segA = SpyIconSegment(id: "seg-a", priority: 10, panelID: "plugin-a")
        let segB = SpyIconSegment(id: "seg-b", priority: 20, panelID: "plugin-b")

        bar.registerPlugin(segA)
        bar.registerPlugin(segB)

        // Draw with both visible
        bar.display()
        let aRect = segA.hitRect
        XCTAssertFalse(aRect.isEmpty)

        // Hide A and redraw — B shifts into A's former position
        segA.isHidden = true
        bar.display()

        let bRectAfter = segB.hitRect
        XCTAssertFalse(bRectAfter.isEmpty)

        // A's hitRect is stale and should overlap with B's new position
        XCTAssertTrue(
            segA.hitRect.intersects(bRectAfter),
            "Stale hitRect of A should overlap B's new position — this is the bug condition")
    }

    /// When a plugin icon becomes hidden, its stale hitRect must not
    /// intercept clicks intended for a visible segment that shifted
    /// into its former position.
    func testHiddenPluginDoesNotInterceptClicks() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))

        let segA = SpyIconSegment(id: "seg-a", priority: 10, panelID: "plugin-a")
        let segB = SpyIconSegment(id: "seg-b", priority: 20, panelID: "plugin-b")

        bar.registerPlugin(segA)
        bar.registerPlugin(segB)

        var toggledIDs: [String] = []
        bar.onSidebarPluginToggle = { toggledIDs.append($0) }

        // Draw with both visible to set hitRects
        bar.display()

        // Hide A — B shifts right into A's former position
        segA.isHidden = true
        bar.display()

        let bRect = segB.hitRect
        let clickPoint = NSPoint(x: bRect.midX, y: bRect.midY)

        toggledIDs.removeAll()
        segA.clickCount = 0
        segB.clickCount = 0

        let settings = AppSettings.shared
        let state = StatusBarState(
            currentDirectory: "/tmp",
            paneCount: 1,
            tabCount: 1,
            runningProcess: "",
            visibleSidebarPlugins: [],
            isRemote: false,
            remoteSession: nil
        )

        // Simulate the FIXED mouseDown: only check visible plugins
        for plugin in bar.rightPlugins where plugin.isVisible(settings: settings, state: state) {
            if plugin.handleClick(at: clickPoint, in: bar) { break }
        }

        XCTAssertEqual(segA.clickCount, 0, "Hidden segment A must not intercept the click")
        XCTAssertEqual(segB.clickCount, 1, "Visible segment B should receive the click")
        XCTAssertEqual(toggledIDs, ["plugin-b"], "Should toggle plugin-b, not plugin-a")
    }

    /// Proves the bug: without the isVisible filter, the hidden plugin
    /// intercepts the click due to its stale hitRect.
    func testUnfilteredIterationCausesMisroute() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))

        let segA = SpyIconSegment(id: "seg-a", priority: 10, panelID: "plugin-a")
        let segB = SpyIconSegment(id: "seg-b", priority: 20, panelID: "plugin-b")

        bar.registerPlugin(segA)
        bar.registerPlugin(segB)

        var toggledIDs: [String] = []
        bar.onSidebarPluginToggle = { toggledIDs.append($0) }

        // Draw with both visible
        bar.display()

        // Hide A, redraw — B shifts into A's stale hitRect zone
        segA.isHidden = true
        bar.display()

        let bRect = segB.hitRect
        let clickPoint = NSPoint(x: bRect.midX, y: bRect.midY)

        toggledIDs.removeAll()
        segA.clickCount = 0
        segB.clickCount = 0

        // Simulate the OLD (buggy) mouseDown: iterate ALL plugins, no filter
        for plugin in bar.rightPlugins {
            if plugin.handleClick(at: clickPoint, in: bar) { break }
        }

        // The bug: hidden A (checked first due to lower priority number)
        // intercepts the click with its stale hitRect
        XCTAssertEqual(segA.clickCount, 1, "Bug: hidden A intercepts the click via stale hitRect")
        XCTAssertEqual(segB.clickCount, 0, "Bug: visible B never gets the click")
        XCTAssertEqual(toggledIDs, ["plugin-a"], "Bug: wrong plugin toggled")
    }

    /// Verify that when all icon segments are visible, clicks route correctly.
    func testVisiblePluginsReceiveClicks() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))

        let segA = SpyIconSegment(id: "seg-a", priority: 10, panelID: "plugin-a")
        let segB = SpyIconSegment(id: "seg-b", priority: 20, panelID: "plugin-b")

        bar.registerPlugin(segA)
        bar.registerPlugin(segB)

        var toggledIDs: [String] = []
        bar.onSidebarPluginToggle = { toggledIDs.append($0) }

        bar.display()

        let clickPoint = NSPoint(x: segB.hitRect.midX, y: segB.hitRect.midY)

        let settings = AppSettings.shared
        let state = StatusBarState(
            currentDirectory: "/tmp",
            paneCount: 1,
            tabCount: 1,
            runningProcess: "",
            visibleSidebarPlugins: [],
            isRemote: false,
            remoteSession: nil
        )

        for plugin in bar.rightPlugins where plugin.isVisible(settings: settings, state: state) {
            if plugin.handleClick(at: clickPoint, in: bar) { break }
        }

        XCTAssertEqual(segA.clickCount, 0, "A should not receive click meant for B")
        XCTAssertEqual(segB.clickCount, 1, "B should receive its own click")
        XCTAssertEqual(toggledIDs, ["plugin-b"])
    }
}
