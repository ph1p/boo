import XCTest

@testable import Boo

final class StatusBarLayoutTests: XCTestCase {
    private let defaults = StatusBarLayout.Arrangement(left: ["env", "path", "git"], right: ["ports", "pane", "time"])

    // MARK: - arrange

    func testNoSavedOrderKeepsDefaults() {
        XCTAssertEqual(StatusBarLayout.arrange(defaults: defaults, leftOrder: [], rightOrder: []), defaults)
    }

    func testSavedOrderAndSidesWin() {
        let result = StatusBarLayout.arrange(
            defaults: defaults, leftOrder: ["git", "time", "env", "path"], rightOrder: ["pane", "ports"])
        XCTAssertEqual(result.left, ["git", "time", "env", "path"])
        XCTAssertEqual(result.right, ["pane", "ports"])
    }

    func testUnknownAndDuplicateIDsAreDropped() {
        let result = StatusBarLayout.arrange(
            defaults: defaults, leftOrder: ["gone", "path", "path", "env", "git"], rightOrder: ["path", "time"])
        XCTAssertEqual(result.left, ["path", "env", "git"])
        XCTAssertEqual(result.right, ["ports", "pane", "time"])
    }

    func testNewSegmentGoesToDefaultSideByRank() {
        // "pane" was never saved (a segment added after the user customised).
        let result = StatusBarLayout.arrange(
            defaults: defaults, leftOrder: ["env", "path", "git"], rightOrder: ["ports", "time"])
        XCTAssertEqual(result.right, ["ports", "pane", "time"])
    }

    // MARK: - moving

    func testMoveAcrossSides() {
        let toLeft = StatusBarLayout.moving("time", toLeft: true, in: defaults)
        XCTAssertEqual(toLeft.left, ["env", "path", "git", "time"])
        XCTAssertEqual(toLeft.right, ["ports", "pane"])

        let toRight = StatusBarLayout.moving("path", toLeft: false, in: defaults)
        XCTAssertEqual(toRight.left, ["env", "git"])
        XCTAssertEqual(toRight.right, ["path", "ports", "pane", "time"])
    }

    func testMoveWithinSideClamps() {
        XCTAssertEqual(StatusBarLayout.moving("path", by: -1, in: defaults).left, ["path", "env", "git"])
        XCTAssertEqual(StatusBarLayout.moving("env", by: -1, in: defaults).left, ["env", "path", "git"])
        XCTAssertEqual(StatusBarLayout.moving("pane", by: 5, in: defaults).right, ["ports", "time", "pane"])
        XCTAssertEqual(StatusBarLayout.moving("missing", by: 1, in: defaults), defaults)
    }

    // MARK: - overflow

    private func m(_ id: String, _ width: CGFloat, _ priority: Int) -> StatusBarLayout.Measured {
        .init(id: id, width: width, collapsePriority: priority)
    }

    func testEverythingFits() {
        let dropped = StatusBarLayout.overflow(
            left: [m("a", 50, 10), m("b", 50, 20)], right: [m("c", 50, 70)], available: 300, separator: 14,
            minGap: 16)
        XCTAssertTrue(dropped.isEmpty)
    }

    func testHighestCollapsePriorityGoesFirst() {
        // Needs 50+14+50 + 16 + 50+50 = 230.
        let dropped = StatusBarLayout.overflow(
            left: [m("a", 50, 10), m("b", 50, 20)], right: [m("c", 50, 70), m("d", 50, 30)], available: 200,
            separator: 14, minGap: 16)
        XCTAssertEqual(dropped, ["c"])
    }

    func testTieDropsInnermostFirst() {
        let dropped = StatusBarLayout.overflow(
            left: [m("a", 50, 40), m("b", 50, 40)], right: [], available: 80, separator: 14, minGap: 16)
        XCTAssertEqual(dropped, ["b"])
    }

    func testPriorityZeroNeverDrops() {
        let dropped = StatusBarLayout.overflow(
            left: [m("a", 100, 0)], right: [m("b", 100, 0), m("c", 40, 60)], available: 50, separator: 14,
            minGap: 16)
        XCTAssertEqual(dropped, ["c"])
    }

    // MARK: - path styles

    func testPathStyles() {
        let path = NSHomeDirectory() + "/.config/boo/themes"
        XCTAssertEqual(PathSegment.display(path, style: .abbreviated), "~/.config/boo/themes")
        XCTAssertEqual(PathSegment.display(path, style: .lastComponent), "themes")
        XCTAssertEqual(PathSegment.display(path, style: .compact), "~/.c/b/themes")
        XCTAssertEqual(PathSegment.display(NSHomeDirectory(), style: .lastComponent), "~")
        XCTAssertEqual(PathSegment.display("/usr/local/bin", style: .compact), "/u/l/bin")
        XCTAssertEqual(PathSegment.display("/", style: .compact), "/")
    }

    // MARK: - settings routing

    @MainActor
    func testHiddenSegmentRouting() {
        let settings = AppSettings.shared
        let savedTime = settings.statusBarShowTime
        let savedHidden = settings.statusBarHiddenSegments
        defer {
            settings.statusBarShowTime = savedTime
            settings.statusBarHiddenSegments = savedHidden
        }

        settings.setStatusBarSegment("time", hidden: true)
        XCTAssertFalse(settings.statusBarShowTime, "Built-in toggles keep their own setting")
        XCTAssertTrue(settings.isStatusBarSegmentHidden("time"))
        settings.setStatusBarSegment("time", hidden: false)
        XCTAssertTrue(settings.statusBarShowTime)

        settings.setStatusBarSegment("kube", hidden: true)
        XCTAssertTrue(settings.statusBarHiddenSegments.contains("kube"))
        XCTAssertTrue(settings.isStatusBarSegmentHidden("kube"))
        settings.setStatusBarSegment("kube", hidden: false)
        XCTAssertFalse(settings.isStatusBarSegmentHidden("kube"))
    }

    // MARK: - bar

    @MainActor
    func testDefaultArrangementMatchesDrawOrder() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 22))
        let arrangement = bar.defaultArrangement
        XCTAssertEqual(arrangement.left, bar.leftPlugins.map(\.id))
        XCTAssertEqual(arrangement.right.last, bar.rightPlugins.first?.id, "Lowest priority sits nearest the edge")
        XCTAssertNotNil(bar.segmentCatalog["time"])
    }
}
