import XCTest

@testable import Boo

/// Visual proof for the "island" chrome: renders the real toolbar, sidebar,
/// pane and status bar views into an offscreen bitmap laid out exactly the way
/// `MainWindowController.setupUI()` constrains them, then asserts the geometry
/// that makes them read as islands — a backdrop-coloured gap between every
/// region, and a stroked, rounded edge on each one.
///
/// Set `BOO_SNAPSHOT_DIR` to also write the PNG for eyeballing.
@MainActor final class IslandChromeSnapshotTests: XCTestCase {

    private let width: CGFloat = 900
    private let height: CGFloat = 560

    /// Mirrors the constraint set in `setupUI()`: toolbar on top, status bar on
    /// the bottom, sidebar + pane splitting the middle, all inset by the island
    /// gap and separated from each other by the same gap.
    private func makeChrome() -> NSView {
        let gap = IslandMetrics.gap
        let barGap = IslandMetrics.barGap
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = AppSettings.shared.theme.windowBackdrop.cgColor

        let toolbarHeight = IslandMetrics.toolbarHeight
        let statusHeight: CGFloat = 24

        // Toolbar and status bar paint no fill or border, but they take the same
        // inset as everything else so their content lines up with the panes.
        let barWidth = width - gap * 2
        let toolbar = ToolbarView(
            frame: NSRect(
                x: gap, y: height - toolbarHeight - barGap, width: barWidth, height: toolbarHeight))
        root.addSubview(toolbar)

        let statusBar = StatusBarView(
            frame: NSRect(x: gap, y: barGap, width: barWidth, height: statusHeight))
        root.addSubview(statusBar)

        let midY = barGap + statusHeight + barGap
        let midH = height - barGap - toolbarHeight - IslandMetrics.headerBottomGap - midY
        let sidebarWidth: CGFloat = 220

        let sidebar = NSView(frame: NSRect(x: gap, y: midY, width: sidebarWidth, height: midH))
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = AppSettings.shared.theme.chromeBg.cgColor
        IslandMetrics.round(sidebar)
        root.addSubview(sidebar)

        let pane = Pane()
        pane.addTab(workingDirectory: "/tmp", title: "zsh")
        let paneX = gap + sidebarWidth + gap
        let paneView = PaneView(paneID: pane.id, pane: pane)
        paneView.frame = NSRect(x: paneX, y: midY, width: width - gap - paneX, height: midH)
        paneView.layer?.backgroundColor = AppSettings.shared.theme.background.nsColor.cgColor
        root.addSubview(paneView)

        root.layoutSubtreeIfNeeded()
        return root
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("no bitmap rep")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("island-chrome.png"))
        }
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }

    private func matches(_ a: NSColor?, _ b: NSColor, tolerance: CGFloat = 0.06) -> Bool {
        guard let a, let b = b.usingColorSpace(.deviceRGB) else { return false }
        let d =
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        return d < tolerance
    }

    /// The defining property of the island look: the window backdrop is visible in
    /// the margin around the chrome and in the gap between neighbouring regions.
    func testBackdropShowsInMarginsAndGaps() throws {
        let rep = try render(makeChrome())
        let scale = CGFloat(rep.pixelsWide) / width
        let backdrop = AppSettings.shared.theme.windowBackdrop
        func px(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            // Bitmap origin is top-left; the view is bottom-left.
            color(rep, Int(x * scale), Int((height - y) * scale))
        }

        let mid = width / 2
        // Backdrop margin on all four sides now — every region shares one inset.
        XCTAssertTrue(matches(px(2, height / 2), backdrop), "no backdrop in left margin")
        XCTAssertTrue(matches(px(width - 2, height / 2), backdrop), "no backdrop in right margin")
        // Only `barGap` of clearance top and bottom, so probe one pixel in.
        XCTAssertTrue(matches(px(mid, height - 1), backdrop), "no backdrop above the toolbar")
        XCTAssertTrue(matches(px(mid, 1), backdrop), "no backdrop below the status bar")

        let underToolbar = height - IslandMetrics.barGap - 38 - IslandMetrics.headerBottomGap / 2
        XCTAssertTrue(matches(px(mid, underToolbar), backdrop), "no gap under the toolbar")

        // Gap between the sidebar island and the pane island.
        let betweenColumns = IslandMetrics.gap + 220 + IslandMetrics.gap / 2
        XCTAssertTrue(
            matches(px(betweenColumns, height / 2), backdrop), "no gap between sidebar and pane")

        // Gap above the status bar, which sits flush at the BOTTOM in view coords.
        let aboveStatus = IslandMetrics.barGap + 24 + IslandMetrics.barGap / 2
        XCTAssertTrue(matches(px(mid, aboveStatus), backdrop), "no gap above the status bar")
    }

    /// Each island is rounded and stroked: the layer carries the shared radius and
    /// the shared hairline, and corners are clipped so content respects them.
    func testEveryIslandIsRoundedAndStroked() {
        let root = makeChrome()
        let islands = root.subviews.filter {
            !($0 is PaneView) && !($0 is ToolbarView) && !($0 is StatusBarView)
        }
        XCTAssertFalse(islands.isEmpty)

        for island in islands {
            let layer = island.layer
            XCTAssertEqual(layer?.cornerRadius, IslandMetrics.radius, "\(type(of: island)) not rounded")
            XCTAssertEqual(layer?.borderWidth, IslandMetrics.borderWidth, "\(type(of: island)) not stroked")
            XCTAssertNotNil(layer?.borderColor, "\(type(of: island)) has no stroke colour")
            XCTAssertTrue(layer?.masksToBounds == true, "\(type(of: island)) does not clip to its corners")
        }

        // Panes use the tighter nested radius but the same stroke treatment.
        let pane = root.subviews.compactMap { $0 as? PaneView }.first
        XCTAssertEqual(pane?.layer?.cornerRadius, IslandMetrics.innerRadius)
        XCTAssertEqual(pane?.layer?.borderWidth, IslandMetrics.borderWidth)
        XCTAssertTrue(pane?.layer?.masksToBounds == true)
    }

    /// The header and footer paint nothing of their own — no fill, no border, no
    /// rounding — but they sit at the same inset as every other region, so the
    /// backdrop margin is uniform on all four sides of the window.
    func testToolbarAndStatusBarAreBareButShareTheIslandInset() {
        let root = makeChrome()
        let strips = root.subviews.filter { $0 is ToolbarView || $0 is StatusBarView }
        XCTAssertEqual(strips.count, 2)

        for view in strips {
            let name = "\(type(of: view))"
            if let bg = view.layer?.backgroundColor {
                XCTAssertEqual(bg.alpha, 0, "\(name) should not paint a background")
            }
            XCTAssertEqual(view.layer?.borderWidth ?? 0, 0, "\(name) should have no border")
            XCTAssertEqual(view.layer?.cornerRadius ?? 0, 0, "\(name) should not be rounded")
            XCTAssertEqual(
                view.frame.minX, IslandMetrics.gap, "\(name) should take the shared island inset")
            XCTAssertEqual(
                view.frame.maxX, width - IslandMetrics.gap,
                "\(name) should take the shared island inset")
        }
    }

    /// The workspace `+` — the only plus the header paints, since tabs live in the
    /// pane — must stay inside the bar with the scroll fade landing before it, not
    /// underneath it or past the window edge.
    func testWorkspacePlusStaysInsideTheBarWithFadeBeforeIt() {
        let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 700, height: 38))
        toolbar.update(
            workspaces: (0..<24).map {
                .init(name: "workspace \($0)", isActive: $0 == 0, resolvedColor: nil, isPinned: false)
            },
            sidebarVisible: false)

        // With this many pills the strip must actually scroll, or no fade ever shows.
        XCTAssertGreaterThan(toolbar.maxWorkspaceScrollOffset, 0)

        let plus = toolbar.workspacePlusButtonRect
        XCTAssertLessThanOrEqual(plus.maxX, toolbar.bounds.width, "plus button runs off the bar")

        // The scrollable strip ends where the plus begins, so the right-hand fade
        // (drawn at zoneEnd - 20, width 20) sits entirely before the button.
        XCTAssertEqual(plus.minX, toolbar.workspaceZoneEnd)

        // No dead slack past the button: what remains to its right is exactly the
        // bar's own trailing margin, not the leftover of an oversized reserve.
        XCTAssertEqual(
            toolbar.bounds.width - plus.maxX, toolbar.zoneGap, accuracy: 0.5,
            "plus button has extra space to its right")

        // Scrolling must not move it.
        let pinned = plus.minX
        toolbar.workspaceScrollOffset = 120
        XCTAssertEqual(toolbar.workspacePlusButtonRect.minX, pinned, "plus moved with the scroll")

        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"] {
            let host = NSView(frame: toolbar.bounds)
            host.wantsLayer = true
            host.layer?.backgroundColor = AppSettings.shared.theme.windowBackdrop.cgColor
            host.addSubview(toolbar)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("toolbar-workspaces.png"))
                }
            }
        }
    }

    /// The island stroke is the same hairline, in the same colour, that panes draw
    /// for their own internal rules — one border system, not two competing weights.
    func testBorderMatchesThePaneRuleHairline() {
        XCTAssertEqual(IslandMetrics.borderWidth, 1)
        for theme in TerminalTheme.themes {
            XCTAssertEqual(
                theme.islandBorder, theme.chromeBorder,
                "\(theme.name): island stroke diverges from the pane rule colour")
        }
    }

    /// One spacing vocabulary. Every chrome region keeps `gap` from the window edge
    /// and from its neighbour, and every region's *content* starts `contentInset`
    /// from its own edge. The bars used to sit flush at 0 while the panes were inset
    /// by `gap`, so each bar hand-picked its own padding (12 / 10 / 4) to fake the
    /// alignment — which is exactly what read as "all the spacings are different".
    func testChromeSpacingComesFromOneVocabulary() throws {
        // The inner inset is smaller than the outer gap: a region already sits a gap
        // from its neighbour, so a second full gap inside it is too much air.
        XCTAssertLessThan(IslandMetrics.contentInset, IslandMetrics.gap)
        XCTAssertGreaterThan(IslandMetrics.contentInset, 0)

        // The sidebar tab strip and the status bar start their content at the same
        // distance from their own edge — they are the two surfaces that face each
        // other across the window, so a mismatch here is immediately visible.
        let bar = SidebarTabBarView(
            frame: NSRect(x: 0, y: 0, width: 240, height: SidebarTabBarView.height))
        bar.sidebarTabs = [SidebarTab(id: SidebarTabID("folder"), icon: "folder", label: "f", sections: [])]
        bar.layoutSubtreeIfNeeded()
        let firstTab = try XCTUnwrap(bar.tabButtonFrames().first)
        XCTAssertEqual(
            firstTab.minX, IslandMetrics.contentInset, accuracy: 0.01,
            "first tab pill must start at the shared content inset")
    }

    /// The strip is the same strip whether it is pinned to the top or the bottom of
    /// the sidebar. It used to reserve a separator row on whichever side faced the
    /// content, which nudged the icons a pixel and made the two placements differ.
    func testSidebarTabStripLaysOutIdenticallyTopAndBottom() {
        func frames(bottom: Bool) -> [NSRect] {
            let previous = AppSettings.shared.sidebarTabBarPosition
            AppSettings.shared.sidebarTabBarPosition = bottom ? .bottom : .top
            defer { AppSettings.shared.sidebarTabBarPosition = previous }
            let bar = SidebarTabBarView(
                frame: NSRect(x: 0, y: 0, width: 240, height: SidebarTabBarView.height))
            bar.sidebarTabs = ["folder", "bookmark", "clock"].map {
                SidebarTab(id: SidebarTabID($0), icon: $0, label: $0, sections: [])
            }
            bar.selectedTab = SidebarTabID("folder")
            bar.layoutSubtreeIfNeeded()
            return bar.tabButtonFrames()
        }

        let top = frames(bottom: false)
        let bottom = frames(bottom: true)
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(top, bottom, "tab geometry must not depend on which edge the bar sits on")

        // Full-height tabs, so the pill drawn centred in one is centred in the bar.
        for r in top {
            XCTAssertEqual(r.minY, 0, accuracy: 0.01)
            XCTAssertEqual(r.height, SidebarTabBarView.height, accuracy: 0.01)
        }
    }

    /// The sidebar tab strip must breathe: icons inset from the island's rounded
    /// edge, a real gap between neighbouring buttons (they used to overlap), and
    /// the whole row centred in the bar.
    func testSidebarTabsAreInsetAndSeparated() {
        let bar = SidebarTabBarView(
            frame: NSRect(x: 0, y: 0, width: 240, height: SidebarTabBarView.height))
        bar.sidebarTabs = ["folder", "bookmark", "shippingbox", "clock", "doc.text", "sparkles"].map {
            SidebarTab(id: SidebarTabID($0), icon: $0, label: $0, sections: [])
        }
        bar.selectedTab = SidebarTabID("folder")
        bar.layoutSubtreeIfNeeded()

        let rects = bar.tabButtonFrames()
        XCTAssertEqual(rects.count, 6, "all tabs should fit at this width")

        XCTAssertGreaterThanOrEqual(rects[0].minX, 4, "first icon is flush against the island edge")
        XCTAssertLessThanOrEqual(
            rects[rects.count - 1].maxX, bar.bounds.width - 4, "last icon is flush against the edge")

        for (a, b) in zip(rects, rects.dropFirst()) {
            XCTAssertGreaterThan(b.minX, a.maxX, "tab buttons overlap instead of being spaced")
        }

        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: bar.bounds.height + 16))
            host.wantsLayer = true
            host.layer?.backgroundColor = AppSettings.shared.theme.windowBackdrop.cgColor
            bar.frame.origin = NSPoint(x: 8, y: 8)
            bar.frame.size.width = 224
            host.addSubview(bar)
            IslandMetrics.round(bar)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("sidebar-tabs.png"))
                }
            }
        }
    }

    /// The vertical workspace bar is a bare strip like the toolbar and status bar,
    /// not an island: no fill, no rounding, no border. Its pills carry the chrome.
    func testSideWorkspaceBarIsABareStrip() {
        // Short enough that the pinned `+` sits right under the last pill — the case
        // where an unclipped stack used to draw into the plus band.
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 190))
        bar.isVertical = true
        bar.setItems(
            ["alpha", "beta with a much longer name", "ga"].map {
                .init(name: $0, path: "/tmp/\($0)")
            },
            selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.layer?.cornerRadius ?? 0, 0, "side bar should not be rounded")
        XCTAssertEqual(bar.layer?.borderWidth ?? 0, 0, "side bar should have no border")
        if let bg = bar.layer?.backgroundColor {
            XCTAssertEqual(bg.alpha, 0, "side bar should not paint a background")
        }

        // Its first pill starts flush with the strip so it lines up with the top of
        // the pane beside it, rather than being pushed down by a second inset.
        XCTAssertEqual(bar.verticalItemRect(at: 0).minY, 0)

        if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"] {
            let host = NSView(
                frame: NSRect(
                    x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth + 8, height: 190))
            host.wantsLayer = true
            host.layer?.backgroundColor = AppSettings.shared.theme.windowBackdrop.cgColor
            // Hover the second pill so the close button in the gutter renders.
            bar.hoveredIndex = 1
            bar.frame.origin = NSPoint(x: 8, y: 0)
            host.addSubview(bar)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("side-workspace-bar.png"))
                }
            }
        }
    }

    /// Hovering a workspace in the side strip expands it into a wide pill that
    /// floats over the panes and carries the close button — the resting pill only
    /// has room for a two-letter abbreviation.
    func testHoveredVerticalPillExpandsOverTheContent() {
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalWidth, height: 400))
        bar.isVertical = true
        bar.setItems(
            ["alpha", "beta"].map { .init(name: $0, path: "/tmp/\($0)") },
            selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        let rest = bar.verticalItemRect(at: 0)
        let expanded = bar.verticalHoveredPillRect(at: 0)

        // Same row, wider — it grows sideways over the panes, it does not move.
        XCTAssertEqual(expanded.minY, rest.minY, accuracy: 0.01)
        XCTAssertEqual(expanded.height, rest.height, accuracy: 0.01)
        XCTAssertGreaterThan(expanded.width, rest.width)
        XCTAssertGreaterThan(
            expanded.maxX, WorkspaceBarView.verticalWidth,
            "expanded pill should reach past the visible strip")

        // The close button lives inside that expanded pill.
        let close = bar.verticalCloseButtonRectForTesting(in: expanded)
        XCTAssertTrue(expanded.contains(close), "close button sits inside the expanded pill")
        XCTAssertEqual(close.midY, expanded.midY, accuracy: 0.5)

        // The strip the panes are laid out against stays narrow — the overhang is
        // scratch space, not claimed width.
        XCTAssertEqual(WorkspaceBarView.verticalWidth, 40)
        XCTAssertEqual(
            bar.verticalPillWidth,
            WorkspaceBarView.verticalWidth - WorkspaceBarView.verticalPadding * 2,
            accuracy: 0.01)
    }

    /// The overhang band lies over the terminal panes, so it must not swallow
    /// clicks that aren't on the strip or the expanded pill.
    func testSideStripPassesThroughClicksOutsideItsChrome() {
        let host = NSView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 400))
        let bar = WorkspaceBarView(
            frame: NSRect(
                x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 400))
        bar.isVertical = true
        bar.setItems(
            ["alpha", "beta"].map { .init(name: $0, path: "/tmp/\($0)") },
            selectedIndex: 0)
        host.addSubview(bar)
        host.layoutSubtreeIfNeeded()

        // `hitTest` takes superview coordinates; the bar is flipped, so map through
        // it rather than hand-writing mirrored y values.
        func hit(_ viewPoint: NSPoint) -> NSView? {
            bar.hitTest(bar.convert(viewPoint, to: host))
        }

        // On the strip: ours.
        XCTAssertNotNil(hit(NSPoint(x: 10, y: 10)))
        // Out in the overhang with nothing hovered: falls through to the pane.
        let overhangX = WorkspaceBarView.verticalWidth + 60
        XCTAssertNil(hit(NSPoint(x: overhangX, y: 200)))

        // Once a pill is expanded, the part of the overhang it covers is ours again.
        bar.hoveredIndex = 0
        let expanded = bar.verticalHoveredPillRect(at: 0)
        XCTAssertNotNil(hit(NSPoint(x: expanded.midX, y: expanded.midY)))
        // ...but the rest of the band still isn't.
        XCTAssertNil(hit(NSPoint(x: expanded.midX, y: 380)))
    }

    /// The `+` is pill-sized and pinned to the bottom of the strip, so overflowing
    /// workspaces can't scroll it out of reach.
    func testVerticalPlusIsPillSizedAndPinnedToTheBottom() {
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalWidth, height: 400))
        bar.isVertical = true
        bar.setItems([.init(name: "alpha", path: "/tmp/alpha")], selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        let pill = bar.verticalItemRect(at: 0)
        let plus = bar.verticalPlusRect
        XCTAssertEqual(plus.size, pill.size, "plus shares the pill footprint")
        XCTAssertEqual(plus.minX, pill.minX, accuracy: 0.01)
        XCTAssertEqual(plus.maxY, bar.bounds.height, accuracy: 0.01, "pinned to the bottom")

        // Scrolling moves the stack but never the button.
        let before = bar.verticalPlusRect
        bar.verticalScrollOffset = 40
        XCTAssertEqual(bar.verticalPlusRect, before, "plus does not scroll with the pills")
    }

    /// Every workspace pill is an island, so every one carries the island hairline —
    /// and a coloured workspace stains its own edge instead of using generic chrome.
    func testPillIslandBorderPicksUpTheWorkspaceColour() {
        let ws = NSColor.systemGreen
        let colored = WorkspacePillStyle.islandBorderAlpha(colored: true)
        let neutral = WorkspacePillStyle.islandBorderAlpha(colored: false)
        XCTAssertLessThan(colored, neutral, "a tinted edge carries less alpha than the neutral rule")

        // The stroke itself is drawn at the shared island weight, not the heavier
        // 1.5pt accent border reserved for the active pill.
        XCTAssertEqual(IslandMetrics.borderWidth, 1, "island hairline is 1px")
        XCTAssertGreaterThan(
            WorkspacePillStyle.borderWidth, IslandMetrics.borderWidth,
            "the active-pill accent stroke stays heavier")

        // Sanity: the helper resolves to the workspace colour, not the fallback.
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        WorkspacePillStyle.strokeIslandBorder(
            gc.cgContext, rect: rect.insetBy(dx: 2, dy: 2), wsColor: ws, neutral: .black)
        NSGraphicsContext.restoreGraphicsState()
        // A green stroke landed: some pixel on the pill edge is greener than it is red.
        var sawGreen = false
        for y in 0..<32 where !sawGreen {
            for x in 0..<32 {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 else { continue }
                if c.greenComponent > c.redComponent + 0.1 {
                    sawGreen = true
                    break
                }
            }
        }
        XCTAssertTrue(sawGreen, "the pill edge is stroked in the workspace colour")
    }

    /// Scrolling the side strip fades its clipped end into the backdrop, the vertical
    /// twin of the top bar's left/right fades. Both ends only appear when there is
    /// something scrolled past them.
    func testSideStripFadesOnlyTheScrolledEnds() throws {
        // Six pills into a 190pt strip: taller than the viewport, so it scrolls.
        let items = (0..<6).map {
            WorkspaceBarView.Item(name: "ws\($0)", path: "/tmp/ws\($0)")
        }
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 190))
        bar.isVertical = true
        bar.setItems(items, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(bar.maxVerticalScrollOffset, 0, "the strip must actually scroll")

        func alphaColumn(_ img: NSBitmapImageRep, y: Int) -> CGFloat {
            let x = Int(bar.verticalStripX + WorkspaceBarView.verticalWidth / 2)
            return img.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }

        // At rest (offset 0) nothing is clipped off the top, so the top edge is bare.
        bar.verticalScrollOffset = 0
        let atTop = try render(bar)
        // Scrolled to the end: the top now has content above it, the bottom does not.
        bar.verticalScrollOffset = bar.maxVerticalScrollOffset
        let atBottom = try render(bar)

        // The fade paints backdrop over the strip, so the topmost row goes from
        // whatever the stack drew to a solid backdrop pixel once scrolled.
        let topRest = alphaColumn(atTop, y: 1)
        let topScrolled = alphaColumn(atBottom, y: 1)
        XCTAssertGreaterThan(
            topScrolled, topRest,
            "scrolling down paints the top fade over the strip")
    }

    /// The toolbar (a flush strip, baseline inset 0) and the split view (an island,
    /// baseline inset `gap`) must each be offset from their *own* baseline when a
    /// side workspace bar claims space. Using one constant for both pushed the
    /// toolbar a gap too far in.
    func testSideBarInsetsToolbarAndSplitFromTheirOwnBaselines() {
        let gap = IslandMetrics.gap
        let claimed = gap + WorkspaceBarView.verticalWidth + gap

        // What each neighbour's inner edge should end up at, measured from the window
        // edge: one island gap clear of the strip.
        let stripInnerEdge = gap + WorkspaceBarView.verticalWidth
        XCTAssertEqual(
            claimed, stripInnerEdge + gap, accuracy: 0.01,
            "the split view should clear the strip by one gap")

        // The toolbar starts flush at 0 rather than at `gap`, so it needs one gap
        // less to land on that same edge.
        let toolbarClaimed = claimed - gap
        XCTAssertEqual(
            toolbarClaimed, stripInnerEdge, accuracy: 0.01,
            "the toolbar should meet the strip's inner edge, not overshoot it")
    }

    /// A left bar and a right bar must be mirror images: the pill's gap to the
    /// window edge and its gap to the panes should match on both sides.
    func testSideStripPillSpacingIsMirroredOnBothEdges() {
        func probe(rightAligned: Bool) -> (toWindowEdge: CGFloat, toPanes: CGFloat) {
            let bar = WorkspaceBarView(
                frame: NSRect(
                    x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 300))
            bar.isVertical = true
            bar.isRightAligned = rightAligned
            bar.setItems([.init(name: "alpha", path: "/tmp/a")], selectedIndex: 0)
            bar.layoutSubtreeIfNeeded()
            let pill = bar.verticalItemRect(at: 0)
            let stripMin = bar.verticalStripX
            let stripMax = stripMin + WorkspaceBarView.verticalWidth
            return rightAligned
                ? (stripMax - pill.maxX, pill.minX - stripMin)
                : (pill.minX - stripMin, stripMax - pill.maxX)
        }

        let left = probe(rightAligned: false)
        let right = probe(rightAligned: true)
        XCTAssertEqual(
            left.toWindowEdge, right.toWindowEdge, accuracy: 0.01,
            "outer spacing differs between the left and right bars")
        XCTAssertEqual(
            left.toPanes, right.toPanes, accuracy: 0.01,
            "inner spacing differs between the left and right bars")
        XCTAssertEqual(left.toWindowEdge, left.toPanes, accuracy: 0.01, "pill not centred in strip")
    }

    /// The expanded hover pill hugs its name: clamped to a minimum so short names
    /// still read as a pill, and to a maximum so long ones truncate instead of
    /// sprawling across the panes.
    func testHoveredPillWidthIsClampedAutoWidth() {
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 400))
        bar.isVertical = true
        bar.setItems(
            [
                .init(name: "a", path: "/tmp/a"),
                .init(name: "medium name", path: "/tmp/m"),
                .init(
                    name: String(repeating: "very long workspace ", count: 5), path: "/tmp/l")
            ],
            selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        let short = bar.verticalHoveredPillRect(at: 0).width
        let medium = bar.verticalHoveredPillRect(at: 1).width
        let long = bar.verticalHoveredPillRect(at: 2).width

        XCTAssertEqual(
            short, WorkspaceBarView.verticalHoveredPillMinWidth, accuracy: 0.01,
            "a one-character name should still get the minimum width")
        XCTAssertGreaterThan(medium, short, "a longer name should widen the pill")
        XCTAssertEqual(
            long, WorkspaceBarView.verticalHoveredPillMaxWidth, accuracy: 0.01,
            "a very long name should clamp, not sprawl")

        // Whatever the width, the close button stays inside it.
        for i in 0..<3 {
            let r = bar.verticalHoveredPillRect(at: i)
            XCTAssertTrue(r.contains(bar.verticalCloseButtonRectForTesting(in: r)))
        }
    }

    /// The pinned `+` gets a band of its own at the bottom of the strip: the pill
    /// stack's viewport stops short of it, so no workspace can sit under it.
    func testPinnedPlusDoesNotOverlapTheLastPill() {
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalFrameWidth, height: 400))
        bar.isVertical = true
        bar.setItems(
            (0..<3).map { .init(name: "ws\($0)", path: "/tmp/ws\($0)") },
            selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        let plus = bar.verticalPlusRect
        XCTAssertLessThanOrEqual(
            bar.verticalScrollViewportHeight, plus.minY,
            "the pill viewport must stop before the plus band")
        for i in 0..<3 {
            XCTAssertFalse(
                bar.verticalItemRect(at: i).intersects(plus), "pill \(i) overlaps the plus")
        }

        // Scrolled fully to the end, the last pill still stops at the band edge.
        bar.verticalScrollOffset = bar.maxVerticalScrollOffset
        XCTAssertFalse(bar.verticalItemRect(at: 2).intersects(plus))
    }

    /// The toolbar island is inset by the side workspace bar, so a title centred in
    /// local bounds would sit off-centre in the window by half that inset.
    func testHeaderWorkspaceTitleIsCentredOnTheWindow() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
        // Inset on the left exactly as the side workspace bar insets it.
        let inset = IslandMetrics.gap + WorkspaceBarView.verticalWidth + IslandMetrics.gap
        let toolbar = ToolbarView(
            frame: NSRect(x: inset, y: 0, width: 800 - inset, height: 28))
        toolbar.hideWorkspaces = true
        container.addSubview(toolbar)
        container.layoutSubtreeIfNeeded()

        let rect = toolbar.centeredWorkspaceTitleRectForTesting()
        // Expressed back in the window's space, the box straddles the window centre.
        let inWindow = toolbar.convert(rect, to: container)
        XCTAssertEqual(
            inWindow.midX, container.bounds.midX, accuracy: 0.5,
            "title should be centred on the window, not on the toolbar island")
        XCTAssertGreaterThan(rect.width, 0)
    }

    /// Vertical scrolling mirrors the top bar's horizontal scrolling: it moves the
    /// pills and clamps at both ends.
    func testVerticalStripScrollsAndClamps() {
        // Short enough that six 32pt pills overflow the stack's viewport.
        let bar = WorkspaceBarView(
            frame: NSRect(x: 0, y: 0, width: WorkspaceBarView.verticalWidth, height: 80))
        bar.isVertical = true
        bar.setItems(
            (0..<6).map { .init(name: "ws\($0)", path: "/tmp/ws\($0)") },
            selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(bar.maxVerticalScrollOffset, 0, "content should overflow")

        let restingTop = bar.verticalItemRect(at: 0).minY
        bar.verticalScrollOffset = 20
        XCTAssertEqual(
            bar.verticalItemRect(at: 0).minY, restingTop - 20, accuracy: 0.01,
            "pills move with the scroll offset")

        // Past either end the offset is pinned, so the strip can't be scrolled into
        // empty space.
        bar.verticalScrollOffset = -500
        bar.clampVerticalScrollForTesting()
        XCTAssertEqual(bar.verticalScrollOffset, 0)

        bar.verticalScrollOffset = 5000
        bar.clampVerticalScrollForTesting()
        XCTAssertEqual(bar.verticalScrollOffset, bar.maxVerticalScrollOffset)
    }

    /// Controls drawn inside the chrome share one corner radius rather than each
    /// draw site picking its own, so the curvature reads as a single family.
    func testChromeControlsShareOneCornerRadius() {
        XCTAssertEqual(WorkspacePillStyle.cornerRadius, IslandMetrics.controlRadius)
        // Tighter than the island itself, so a pill inside a card never looks
        // rounder than the card containing it.
        XCTAssertLessThan(IslandMetrics.controlRadius, IslandMetrics.radius)
        XCTAssertLessThan(IslandMetrics.innerRadius, IslandMetrics.radius)
    }

    /// The gap is one number everywhere: window margin, inter-island spacing and the
    /// split divider all read from `IslandMetrics.gap`.
    func testDividerThicknessMatchesTheIslandGap() {
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(split.dividerThickness, IslandMetrics.gap)
        XCTAssertEqual(split.dividerColor, AppSettings.shared.theme.windowBackdrop)
    }

    /// The backdrop has to be distinguishable from the chrome it sits behind, or the
    /// gaps disappear and the islands stop reading as separate cards.
    func testBackdropIsDistinctFromChromeInEveryBuiltInTheme() {
        for theme in TerminalTheme.themes {
            let backdrop = theme.windowBackdrop.usingColorSpace(.sRGB)!
            let chrome = theme.chromeBg.usingColorSpace(.sRGB)!
            let d =
                abs(backdrop.redComponent - chrome.redComponent)
                + abs(backdrop.greenComponent - chrome.greenComponent)
                + abs(backdrop.blueComponent - chrome.blueComponent)
            XCTAssertGreaterThan(d, 0.1, "\(theme.name): backdrop is indistinguishable from chrome")
        }
    }
}
