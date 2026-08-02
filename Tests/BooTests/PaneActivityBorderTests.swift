import XCTest

@testable import Boo

/// The activity frame must wrap the WHOLE pane, not just the tab bar — terminal and
/// content subviews cover everything below the tab bar, so it lives in an overlay
/// subview that must stay topmost, click-through, and sized to the pane bounds.
@MainActor final class PaneActivityBorderTests: XCTestCase {

    /// Builds a laid-out pane view with the activity frame already synced.
    private func makePaneView(focused: Bool = false, activityAt: Int? = nil, tabs: Int = 2) -> PaneView {
        let pane = Pane()
        for i in 0..<tabs { pane.addTab(workingDirectory: "/tmp", title: "t\(i)") }
        let pv = PaneView(paneID: pane.id, pane: pane)
        pv.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pv.isFocused = focused
        if let activityAt { pane.setActivity(true, at: activityAt) }
        pv.updateActivityBorder()
        pv.updateOverlayColors()
        pv.layoutSubtreeIfNeeded()
        return pv
    }

    func testHiddenWithoutActivity() {
        XCTAssertTrue(makePaneView().activityBorder.isHidden)
    }

    func testVisibleWhenUnfocusedTabHasActivity() {
        XCTAssertFalse(makePaneView(activityAt: 1).activityBorder.isHidden)
    }

    func testHiddenWhileFocused() {
        XCTAssertTrue(makePaneView(focused: true, activityAt: 1).activityBorder.isHidden)
    }

    func testClearsWhenActivityFlagCleared() {
        let pv = makePaneView(activityAt: 0)
        XCTAssertFalse(pv.activityBorder.isHidden)
        pv.pane.setActivity(false, at: 0)
        pv.updateActivityBorder()
        XCTAssertTrue(pv.activityBorder.isHidden)
    }

    /// Focusing a pane must drop the frame without any explicit sync call — the
    /// production path is `isFocused.didSet`, not `draw(_:)`.
    func testFocusChangeDrivesBorderWithoutRedraw() {
        let pv = makePaneView(activityAt: 0)
        pv.isFocused = true
        XCTAssertTrue(pv.activityBorder.isHidden)
        pv.isFocused = false
        XCTAssertFalse(pv.activityBorder.isHidden)
    }

    /// Regression: the old implementation painted the border in `draw(_:)`, where
    /// content subviews hid every edge except the tab bar strip.
    func testOverlayCoversWholePaneAndStaysTopmost() {
        let pv = makePaneView(activityAt: 0)
        XCTAssertEqual(pv.activityBorder.frame, pv.bounds)
        XCTAssertTrue(pv.subviews.last === pv.activityBorder)
    }

    /// Border, not blur/shadow: a plain layer border, no shadow, no fill.
    func testBorderOnlyNoShadowOrBlur() {
        let layer = makePaneView(activityAt: 0).activityBorder.layer
        XCTAssertEqual(layer?.borderWidth, PaneView.activityBorderWidth)
        XCTAssertNotNil(layer?.borderColor)
        XCTAssertEqual(layer?.shadowOpacity, 0)
        XCTAssertNil(layer?.backgroundColor)
        XCTAssertNil(layer?.filters)
    }

    /// Visual proof: render the pane offscreen and assert accent-colored pixels appear
    /// on all four edges (mid-height left/right included — the old draw()-based border
    /// was invisible there). Writes a PNG to BOO_SNAPSHOT_DIR when set, for eyeballing.
    func testRenderedBorderPixelsOnAllFourEdges() throws {
        let pv = makePaneView(activityAt: 0)

        guard let rep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) else {
            return XCTFail("no bitmap rep")
        }
        pv.cacheDisplay(in: pv.bounds, to: rep)

        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pane-activity-border.png"))
        }

        let accent = AppSettings.shared.theme.accentColor.usingColorSpace(.deviceRGB)!
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            // Overlay alpha is 0.8 over the pane background, so match loosely on hue distance.
            let d =
                abs(c.redComponent - accent.redComponent) + abs(c.greenComponent - accent.greenComponent)
                + abs(c.blueComponent - accent.blueComponent)
            return d < 0.35
        }

        let w = Int(rep.pixelsWide)
        let h = Int(rep.pixelsHigh)
        let midX = w / 2
        let midY = h / 2
        XCTAssertTrue(isAccent(midX, 0) || isAccent(midX, 1), "top edge not painted")
        XCTAssertTrue(isAccent(midX, h - 1) || isAccent(midX, h - 2), "bottom edge not painted")
        XCTAssertTrue(isAccent(0, midY) || isAccent(1, midY), "left edge not painted at mid-height")
        XCTAssertTrue(isAccent(w - 1, midY) || isAccent(w - 2, midY), "right edge not painted at mid-height")
        // Interior must stay untouched — border only, no tint/blur over the content.
        XCTAssertFalse(isAccent(midX, midY), "pane interior should not be tinted")
    }

    /// Click-through: the overlay must never steal mouse events from the terminal.
    func testOverlayIsClickThrough() {
        let pv = makePaneView(activityAt: 0)
        XCTAssertNil(pv.activityBorder.hitTest(NSPoint(x: 300, y: 200)))
    }
}
