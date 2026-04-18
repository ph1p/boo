import SwiftUI
import XCTest

@testable import Boo

// MARK: - Helper

/// A non-trivial SwiftUI view for testing (like real plugin content).
private struct MockPluginContent: View {
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                    Text("\(label) item \(i)")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
    }
}

nonisolated(unsafe) private var sectionGenCounter: UInt64 = 0
private func makeSection(id: String, name: String = "Test") -> SidebarSection {
    sectionGenCounter += 1
    return SidebarSection(
        id: id,
        name: name,
        icon: "star",
        content: AnyView(MockPluginContent(label: name)),
        prefersOuterScrollView: true,
        generation: sectionGenCounter
    )
}

private func makeNonGrowableSection(id: String, name: String = "Info") -> SidebarSection {
    sectionGenCounter += 1
    return SidebarSection(
        id: id,
        name: name,
        icon: "info.circle",
        content: AnyView(MockPluginContent(label: name)),
        prefersOuterScrollView: false,
        generation: sectionGenCounter
    )
}

private func makePanelView(width: CGFloat = 240, height: CGFloat = 500) -> SidebarPanelView {
    SidebarPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
}

private func mouseDownEvent(for window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: window.convertPoint(fromScreen: .zero),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1.0
    )!
}

@MainActor final class SidebarLayoutTests: XCTestCase {

    // MARK: - Adding Panels

    func testAddSingleExpanded() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates.count, 1)
        XCTAssertTrue(v.sectionStates[0].isExpanded)
    }

    func testAddSingleCollapsed() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 1)
        XCTAssertFalse(v.sectionStates[0].isExpanded)
    }

    func testAddMultipleSections() {
        let v = makePanelView()
        v.updateSections(
            [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")], expandedIDs: ["a", "b", "c"])
        XCTAssertEqual(v.sectionStates.count, 3)
    }

    func testAddMixedExpandedCollapsed() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")], expandedIDs: ["a", "c"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
    }

    func testAddEmpty() {
        let v = makePanelView()
        v.updateSections([], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 0)
    }

    // MARK: - Removing Panels

    func testRemoveSection() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a", "b"])
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates.count, 1)
    }

    func testRemoveAllSections() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        v.updateSections([], expandedIDs: [])
        XCTAssertEqual(v.sectionStates.count, 0)
    }

    func testReplaceSections() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a"])
        v.updateSections([makeSection(id: "c"), makeSection(id: "d")], expandedIDs: ["c", "d"])
        XCTAssertEqual(v.sectionStates.count, 2)
        XCTAssertEqual(v.sectionStates[0].id, "c")
    }

    // MARK: - Fold / Unfold

    func testCollapseSection() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertEqual(v.sectionStates[0].contentHeight, 0)
    }

    func testExpandSection() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertGreaterThan(v.sectionStates[1].contentHeight, 0)
    }

    func testCollapseAllSections() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: [])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
    }

    func testExpandAllFromCollapsed() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: [])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
    }

    func testToggleBackAndForth() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
    }

    // MARK: - Expand last doesn't disturb collapsed middle

    func testExpandLastDoesNotExpandMiddle() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "c"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertEqual(v.sectionStates[1].contentHeight, 0)
    }

    func testExpandLastFromAllCollapsed() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: [])
        v.updateSections(s, expandedIDs: ["c"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertGreaterThan(v.sectionStates[2].contentHeight, SidebarLayout.minSectionHeight - 1)
    }

    func testExpandMiddle() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a"])
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertFalse(v.sectionStates[2].isExpanded)
    }

    func testCollapseFirstThenExpandLast() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.updateSections(s, expandedIDs: ["b"])
        v.updateSections(s, expandedIDs: ["b", "c"])
        XCTAssertFalse(v.sectionStates[0].isExpanded)
        XCTAssertTrue(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
    }

    // MARK: - Layout correctness

    func testCollapsedSectionHasZeroContentHeight() {
        let v = makePanelView()
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[1].contentHeight, 0)
    }

    func testExpandedSectionHasPositiveContentHeight() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertGreaterThan(v.sectionStates[0].contentHeight, 0)
    }

    func testHeaderViewsAreSubviews() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a"), makeSection(id: "b")], expandedIDs: ["a"])
        // 2 headers + 1 content hosting = 3 subviews
        XCTAssertEqual(v.subviews.count, 3)
    }

    func testCollapsedNoContentHosting() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: [])
        XCTAssertNil(v.sectionStates[0].contentContainer)
    }

    func testExpandedHasContentHosting() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertNotNil(v.sectionStates[0].contentContainer)
    }

    func testCollapseRemovesContentHosting() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertNotNil(v.sectionStates[0].contentContainer)
        v.updateSections(s, expandedIDs: [])
        XCTAssertNil(v.sectionStates[0].contentContainer)
    }

    // MARK: - Idempotency

    func testUpdateSameSectionsIdempotent() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        v.updateSections(s, expandedIDs: ["a"])
        let h = v.sectionStates[0].contentHeight
        v.updateSections(s, expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[0].contentHeight, h, accuracy: 1)
    }

    // MARK: - Dynamic names

    func testUpdateSectionName() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a", name: "Files")], expandedIDs: ["a"])
        v.updateSections([makeSection(id: "a", name: "Projects")], expandedIDs: ["a"])
        XCTAssertEqual(v.sectionStates[0].name, "Projects")
    }

    // MARK: - Toggle callback

    @MainActor func testToggleCallbackFires() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let v = makePanelView()
        var toggled: String?
        v.onToggleExpand = { id in toggled = id }
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(v)
        v.frame = window.contentView?.bounds ?? .zero

        v.sectionStates[0].headerView.mouseDown(with: mouseDownEvent(for: window))
        XCTAssertEqual(toggled, "a")
    }

    // MARK: - Header view

    func testHeaderViewCreation() {
        let h = SidebarSectionHeaderView(sectionID: "x", name: "T", icon: "star", isExpanded: true)
        XCTAssertEqual(h.sectionID, "x")
        XCTAssertTrue(h.isFlipped)
    }

    @MainActor func testHeaderViewMouseDownInvokesToggleWithSectionID() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let h = SidebarSectionHeaderView(sectionID: "x", name: "A", icon: "star", isExpanded: false)
        var toggled: String?
        h.onToggle = { toggled = $0 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        h.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(h)

        h.mouseDown(with: mouseDownEvent(for: window))
        XCTAssertEqual(toggled, "x")
    }

    // MARK: - Four sections stress

    func testFourSectionsAllExpanded() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        XCTAssertEqual(v.sectionStates.count, 4)
        XCTAssertTrue(v.sectionStates.allSatisfy(\.isExpanded))
    }

    func testFourSectionsAlternating() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: ["s0", "s2"])
        XCTAssertTrue(v.sectionStates[0].isExpanded)
        XCTAssertFalse(v.sectionStates[1].isExpanded)
        XCTAssertTrue(v.sectionStates[2].isExpanded)
        XCTAssertFalse(v.sectionStates[3].isExpanded)
    }

    func testFourSectionsCycleExpandCollapse() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        for id in allIDs.sorted() {
            v.updateSections(s, expandedIDs: allIDs.subtracting([id]))
        }
        v.updateSections(s, expandedIDs: allIDs)
        XCTAssertEqual(v.sectionStates.count, 4)
        XCTAssertTrue(v.sectionStates.allSatisfy(\.isExpanded))
    }

    // MARK: - Drag resize

    func testDragOnlyAffectsTwoAdjacentSections() {
        let v = makePanelView(height: 600)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight
        let h3 = v.sectionStates[3].contentHeight

        // Drag between section 2 and 3 — only s2 and s3 should change
        v.handleDrag(
            aboveIndex: 2, belowIndex: 3, delta: 30,
            startHeights: (h2, h3))

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, h0, accuracy: 0.5,
            "Section 0 should not change during drag between 2 and 3")
        XCTAssertEqual(
            v.sectionStates[1].contentHeight, h1, accuracy: 0.5,
            "Section 1 should not change during drag between 2 and 3")
    }

    func testDragPreservesTotalOfTwoSections() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let total = h0 + h1

        // Drag down: section 0 grows, section 1 shrinks
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 50,
            startHeights: (h0, h1))

        let newTotal = v.sectionStates[0].contentHeight + v.sectionStates[1].contentHeight
        XCTAssertEqual(
            newTotal, total, accuracy: 0.5,
            "Sum of the two dragged sections must be preserved")
    }

    func testDragCannotShrinkBelowMinHeight() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight

        // Drag down by a huge amount — should clamp at min height for below
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 9999,
            startHeights: (h0, h1))

        XCTAssertGreaterThanOrEqual(
            v.sectionStates[1].contentHeight,
            SidebarLayout.minSectionHeight,
            "Below section should not go below min height")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[0].contentHeight,
            SidebarLayout.minSectionHeight,
            "Above section should not go below min height")
    }

    func testDragUpCannotShrinkAboveBelowMinHeight() {
        let v = makePanelView(height: 400)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight

        // Drag up by a huge amount — should clamp at min height for above
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: -9999,
            startHeights: (h0, h1))

        XCTAssertGreaterThanOrEqual(
            v.sectionStates[0].contentHeight,
            SidebarLayout.minSectionHeight,
            "Above section should not go below min height")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[1].contentHeight,
            SidebarLayout.minSectionHeight,
            "Below section should not go below min height")
    }

    func testDragPastWindowEdgeDoesNotAffectOtherSections() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight

        // Drag the last handle (between s1 and s2) way past the window
        v.handleDrag(
            aboveIndex: 1, belowIndex: 2, delta: 2000,
            startHeights: (h1, h2))

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, h0, accuracy: 0.5,
            "Section 0 must not change when dragging handle between 1 and 2 past edge")
        XCTAssertGreaterThanOrEqual(
            v.sectionStates[2].contentHeight,
            SidebarLayout.minSectionHeight,
            "Last section should be clamped to min, not negative")
    }

    func testDragDoesNotCreateOverflow() {
        let v = makePanelView(height: 400)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight

        // Drag between 0 and 1
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 30,
            startHeights: (h0, h1))

        // Total content height should not exceed available
        let available =
            v.bounds.height
            - CGFloat(3) * SidebarLayout.headerHeight
            - CGFloat(2) * SidebarLayout.separatorHeight
        let total = v.sectionStates.filter(\.isExpanded)
            .reduce(CGFloat(0)) { $0 + $1.contentHeight }
        XCTAssertLessThanOrEqual(
            total, available + 1,
            "Total content height must not exceed available space after drag")
    }

    func testCollapseRedistributesSpaceToRemaining() {
        let v = makePanelView(height: 500)
        let s = (0..<4).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        v.layoutAllSections()

        // Collapse the last section
        v.updateSections(s, expandedIDs: allIDs.subtracting(["s3"]))
        v.layoutAllSections()

        // The remaining 3 expanded sections should fill the available space
        let headers = CGFloat(4) * SidebarLayout.headerHeight
        let seps = CGFloat(3) * SidebarLayout.separatorHeight
        let availableContent = v.bounds.height - headers - seps
        let expandedSum = v.sectionStates.filter(\.isExpanded)
            .reduce(CGFloat(0)) { $0 + $1.contentHeight }

        XCTAssertEqual(
            expandedSum, availableContent, accuracy: 2,
            "Remaining expanded sections should fill available space after collapse")
        XCTAssertEqual(
            v.sectionStates[3].contentHeight, 0,
            "Collapsed section should have zero content height")
    }

    func testCollapseLastSectionPushesHeaderToBottom() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        let allIDs = Set(s.map(\.id))
        v.updateSections(s, expandedIDs: allIDs)
        v.layoutAllSections()

        // Collapse the last one
        v.updateSections(s, expandedIDs: allIDs.subtracting(["s2"]))
        v.layoutAllSections()

        // The collapsed header should be positioned after all expanded content
        let lastHeader = v.sectionStates[2].headerView
        let expandedBottom = v.sectionStates[1].headerView.frame.maxY + v.sectionStates[1].contentHeight
        let expectedY = expandedBottom + SidebarLayout.separatorHeight

        XCTAssertEqual(
            lastHeader.frame.origin.y, expectedY, accuracy: 1,
            "Collapsed last section header should sit right below expanded content")
    }

    func testMultipleDragsInSequence() {
        let v = makePanelView(height: 500)
        let s = (0..<3).map { makeSection(id: "s\($0)") }
        v.updateSections(s, expandedIDs: Set(s.map(\.id)))
        v.layoutAllSections()

        // Drag handle 0-1 down
        let h0 = v.sectionStates[0].contentHeight
        let h1 = v.sectionStates[1].contentHeight
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 40,
            startHeights: (h0, h1))

        // Now drag handle 1-2 down
        let h1b = v.sectionStates[1].contentHeight
        let h2 = v.sectionStates[2].contentHeight
        v.handleDrag(
            aboveIndex: 1, belowIndex: 2, delta: 30,
            startHeights: (h1b, h2))

        // Section 0 should be unchanged from its post-first-drag value
        let expected0 = min(h0 + h1 - SidebarLayout.minSectionHeight, max(SidebarLayout.minSectionHeight, h0 + 40))
        XCTAssertEqual(
            v.sectionStates[0].contentHeight, expected0, accuracy: 0.5,
            "Section 0 must remain stable after second drag on a different handle")

        // All sections should still be at least min height
        for (i, state) in v.sectionStates.enumerated() where state.isExpanded {
            XCTAssertGreaterThanOrEqual(
                state.contentHeight, SidebarLayout.minSectionHeight,
                "Section \(i) should be at least min height after sequential drags")
        }
    }

    // MARK: - Scroll Position Per Terminal

    func testSetTerminalIDSavesScrollOffsets() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])

        // Simulate scrolling by directly setting the scroll view offset
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch to terminal 2 — should save terminal 1's offsets
        v.setTerminalID(tid2)

        let saved = v.scrollOffset(for: tid1, sectionID: "a")
        XCTAssertNotNil(saved, "Scroll offset should be saved for terminal 1")
        XCTAssertEqual(saved?.y ?? -1, 42, accuracy: 1, "Saved scroll offset should match")
    }

    func testScrollOffsetRestoredOnTerminalSwitch() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        // Terminal 1: scroll to y=42
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch to terminal 2: scroll to y=100
        v.setTerminalID(tid2)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Switch back to terminal 1 — should restore y=42
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])

        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            let offset = scrollView.contentView.bounds.origin
            XCTAssertEqual(offset.y, 42, accuracy: 1, "Scroll position should be restored for terminal 1")
        }
    }

    func testScrollOffsetIndependentPerTerminal() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid1 = UUID()
        let tid2 = UUID()

        // Terminal 1 at y=20
        v.setTerminalID(tid1)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Terminal 2 at y=80
        v.setTerminalID(tid2)
        v.updateSections(s, expandedIDs: ["a"])
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 80))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Explicitly save terminal 2's offsets before checking
        v.saveScrollOffsets(for: tid2)

        // Verify both are stored independently
        let saved1 = v.scrollOffset(for: tid1, sectionID: "a")
        let saved2 = v.scrollOffset(for: tid2, sectionID: "a")
        XCTAssertEqual(saved1?.y ?? -1, 20, accuracy: 1)
        XCTAssertEqual(saved2?.y ?? -1, 80, accuracy: 1)
    }

    func testScrollOffsetSavedPerSection() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        let tid = UUID()

        v.setTerminalID(tid)
        v.updateSections(s, expandedIDs: ["a", "b"])

        // Scroll section a to y=10, section b to y=50
        for (i, expected) in [(0, 10.0), (1, 50.0)] {
            if let scrollView = v.sectionStates[i].contentContainer as? NSScrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: expected))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        // Save and check
        v.saveScrollOffsets(for: tid)
        XCTAssertEqual(v.scrollOffset(for: tid, sectionID: "a")?.y ?? -1, 10, accuracy: 1)
        XCTAssertEqual(v.scrollOffset(for: tid, sectionID: "b")?.y ?? -1, 50, accuracy: 1)
    }

    func testNoSavedOffsetForUnknownTerminal() {
        let v = makePanelView()
        let offset = v.scrollOffset(for: UUID(), sectionID: "a")
        XCTAssertNil(offset)
    }

    func testSameTerminalIDDoesNotSave() {
        let v = makePanelView()
        let s = [makeSection(id: "a")]
        let tid = UUID()

        v.setTerminalID(tid)
        v.updateSections(s, expandedIDs: ["a"])

        // Scroll to y=42
        if let scrollView = v.sectionStates[0].contentContainer as? NSScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Set same terminal ID again — should NOT trigger a save (no transition)
        v.setTerminalID(tid)
        // Offset should not be saved because oldID == newID
        let saved = v.scrollOffset(for: tid, sectionID: "a")
        XCTAssertNil(saved, "Same terminal should not trigger save")
    }

    // MARK: - Real plugin E2E: use actual BookmarksPlugin content in a window

    /// Uses the real BookmarksPlugin to generate content, in a real NSWindow,
    /// with the exact toggle-rebuild cycle from MainWindowController.
    @MainActor func testClickBookmarkHeaderWithRealPlugin() throws {
        try XCTSkipIf(!NSApplication.shared.isRunning, "Requires a running NSApplication event loop")
        let _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)

        let panel = SidebarPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            panel.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        // Use the real plugins to generate content
        let registry = PluginRegistry()
        registry.registerBuiltins()
        let context = TerminalContext(
            terminalID: UUID(),
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            remoteSession: nil,
            gitContext: nil,
            processName: "zsh",
            paneCount: 1,
            tabCount: 1
        )
        var expandedIDs: Set<String> = ["file-tree-local"]

        func makeSections() -> [SidebarSection] {
            var sections: [SidebarSection] = []
            for pluginID in ["file-tree-local", "docker", "bookmarks"] {
                guard let plugin = registry.plugin(for: pluginID),
                    plugin.isVisible(for: context)
                else {
                    continue
                }
                let pluginCtx = registry.buildPluginContext(for: pluginID, terminal: context)
                guard let content = plugin.makeDetailView(context: pluginCtx) else {
                    continue
                }
                sections.append(
                    SidebarSection(
                        id: pluginID,
                        name: plugin.sectionTitle(context: pluginCtx) ?? plugin.manifest.name,
                        icon: plugin.manifest.icon,
                        content: content,
                        prefersOuterScrollView: plugin.prefersOuterScrollView,
                        generation: 0
                    ))
            }
            return sections
        }

        func rebuild() {
            let sections = makeSections()
            panel.onToggleExpand = { id in
                if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
                // Exact same pattern as MainWindowController.rebuildPluginSidebar
                let newSections = makeSections()
                panel.updateSections(newSections, expandedIDs: expandedIDs)
            }
            panel.updateSections(sections, expandedIDs: expandedIDs)
        }

        // Initial load
        rebuild()
        window.layoutIfNeeded()

        let sectionCount = panel.sectionStates.count
        XCTAssertGreaterThan(sectionCount, 0, "Should have visible plugin sections")

        // Find bookmarks section
        let bmIndex = panel.sectionStates.firstIndex(where: { $0.id == "bookmarks" })
        XCTAssertNotNil(bmIndex, "Bookmarks section should exist")
        guard let idx = bmIndex else {
            window.close()
            return
        }

        XCTAssertFalse(panel.sectionStates[idx].isExpanded, "Bookmarks should start collapsed")

        // Click the bookmarks header — THIS IS WHAT CRASHES IN THE REAL APP
        let bmHeader = panel.sectionStates[idx].headerView
        bmHeader.mouseDown(with: mouseDownEvent(for: window))
        window.layoutIfNeeded()

        // Verify it expanded without crashing
        XCTAssertTrue(
            panel.sectionStates[idx].isExpanded,
            "Bookmarks should be expanded after clicking header")

        // Click again to collapse
        panel.sectionStates[idx].headerView.mouseDown(with: mouseDownEvent(for: window))
        window.layoutIfNeeded()

        XCTAssertFalse(
            panel.sectionStates[idx].isExpanded,
            "Bookmarks should be collapsed after second click")

        // Click ALL headers to expand everything
        for i in 0..<panel.sectionStates.count {
            if !panel.sectionStates[i].isExpanded {
                panel.sectionStates[i].headerView.mouseDown(with: mouseDownEvent(for: window))
                window.layoutIfNeeded()
            }
        }
        XCTAssertTrue(
            panel.sectionStates.allSatisfy(\.isExpanded),
            "All sections should be expanded")

        window.close()
    }

    // MARK: - Auto Layout document height (overflow:auto style)

    func testDocumentViewUsesAutoLayout() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        v.layoutAllSections()

        guard let scrollView = v.sectionStates[0].contentContainer as? NSScrollView,
            let docView = scrollView.documentView
        else {
            XCTFail("Expected scroll view with document view")
            return
        }
        // The hosting view should use Auto Layout (translatesAutoresizingMaskIntoConstraints = false)
        XCTAssertFalse(
            docView.translatesAutoresizingMaskIntoConstraints,
            "Document view should use Auto Layout constraints")
    }

    func testDocumentViewPinnedToScrollContentView() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        v.layoutAllSections()

        guard let scrollView = v.sectionStates[0].contentContainer as? NSScrollView,
            let docView = scrollView.documentView
        else {
            XCTFail("Expected scroll view with document view")
            return
        }
        // Should have constraints pinning to the content view
        let constraints = scrollView.contentView.constraints
        let hasTopPin = constraints.contains { c in
            (c.firstItem === docView && c.firstAttribute == .top)
                || (c.secondItem === docView && c.secondAttribute == .top)
        }
        let hasLeadingPin = constraints.contains { c in
            (c.firstItem === docView && c.firstAttribute == .leading)
                || (c.secondItem === docView && c.secondAttribute == .leading)
        }
        XCTAssertTrue(hasTopPin, "Document view should be pinned to top of content view")
        XCTAssertTrue(hasLeadingPin, "Document view should be pinned to leading of content view")
    }

    func testScrollViewContainerIsScrollView() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        XCTAssertTrue(
            v.sectionStates[0].contentContainer is NSScrollView,
            "Content container should be an NSScrollView for prefersOuterScrollView sections")
    }

    func testDocumentViewHasPositiveIntrinsicHeight() {
        let v = makePanelView()
        v.updateSections([makeSection(id: "a")], expandedIDs: ["a"])
        v.layoutAllSections()

        guard let scrollView = v.sectionStates[0].contentContainer as? NSScrollView,
            let docView = scrollView.documentView
        else {
            XCTFail("Expected scroll view with document view")
            return
        }
        let intrinsic = docView.intrinsicContentSize.height
        XCTAssertGreaterThan(
            intrinsic, 0,
            "Document view intrinsic height should be positive (is \(intrinsic))")
    }

    func testNonScrollSectionUsesDirectHosting() {
        sectionGenCounter += 1
        let section = SidebarSection(
            id: "direct",
            name: "Direct",
            icon: "star",
            content: AnyView(Text("Hello")),
            prefersOuterScrollView: false,
            generation: sectionGenCounter
        )
        let v = makePanelView()
        v.updateSections([section], expandedIDs: ["direct"])
        XCTAssertFalse(
            v.sectionStates[0].contentContainer is NSScrollView,
            "Non-scroll section should use direct hosting, not NSScrollView")
    }

    // MARK: - Height Persistence Across Rebuilds

    func testHeightSurvivesFullRebuild() {
        let v = makePanelView(height: 500)
        let s1 = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s1, expandedIDs: ["a", "b"])

        // Simulate drag resize — set custom height
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 50,
            startHeights: (v.sectionStates[0].contentHeight, v.sectionStates[1].contentHeight))
        let heightA = v.sectionStates[0].contentHeight
        let heightB = v.sectionStates[1].contentHeight

        // Full rebuild (section IDs change then change back — forces rebuild path)
        let s2 = [makeSection(id: "c")]
        v.updateSections(s2, expandedIDs: ["c"])

        // Rebuild with original sections
        let s3 = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s3, expandedIDs: ["a", "b"])

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, heightA, accuracy: 1,
            "Height of section A should be restored after rebuild")
        XCTAssertEqual(
            v.sectionStates[1].contentHeight, heightB, accuracy: 1,
            "Height of section B should be restored after rebuild")
    }

    func testHeightSurvivesCollapseAndReExpand() {
        let v = makePanelView(height: 800)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])

        // Resize — small delta to stay within bounds
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 30,
            startHeights: (v.sectionStates[0].contentHeight, v.sectionStates[1].contentHeight))

        // Collapse A
        v.updateSections(s, expandedIDs: ["b"])
        XCTAssertEqual(v.sectionStates[0].contentHeight, 0)

        // Re-expand A — height is restored from saved, then clamped to fit.
        // The total may need redistribution, so allow wider tolerance.
        v.updateSections(s, expandedIDs: ["a", "b"])
        XCTAssertGreaterThan(
            v.sectionStates[0].contentHeight, SidebarLayout.minSectionHeight,
            "Restored height should be larger than minimum")
    }

    func testHeightSurvivesPluginAppearDisappear() {
        let v = makePanelView(height: 800)

        // Start with files + git
        let s1 = [makeSection(id: "files"), makeSection(id: "git")]
        v.updateSections(s1, expandedIDs: ["files", "git"])

        // Resize — small delta
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 30,
            startHeights: (v.sectionStates[0].contentHeight, v.sectionStates[1].contentHeight))
        let filesHeight = v.sectionStates[0].contentHeight

        // AI agent appears — saved height is restored but may be clamped
        let s2 = [makeSection(id: "files"), makeSection(id: "git"), makeSection(id: "ai")]
        v.updateSections(s2, expandedIDs: ["files", "git", "ai"])

        // Height may be slightly reduced to fit 3 sections, but should be close
        XCTAssertGreaterThan(
            v.sectionStates[0].contentHeight, SidebarLayout.minSectionHeight,
            "Files should have more than minimum height")

        // AI agent disappears — files should get closer to original height
        let s3 = [makeSection(id: "files"), makeSection(id: "git")]
        v.updateSections(s3, expandedIDs: ["files", "git"])

        XCTAssertEqual(
            v.sectionStates[0].contentHeight, filesHeight, accuracy: 5,
            "Files height should be preserved when AI plugin disappears")
    }

    func testNewSectionGetsDefaultHeight() {
        let v = makePanelView(height: 500)

        // Start with one section
        let s1 = [makeSection(id: "a")]
        v.updateSections(s1, expandedIDs: ["a"])

        // Add a new section (never seen before — should get intrinsic/default height)
        let s2 = [makeSection(id: "a"), makeSection(id: "new")]
        v.updateSections(s2, expandedIDs: ["a", "new"])

        XCTAssertGreaterThan(
            v.sectionStates[1].contentHeight, 0,
            "New section should have positive height")
    }

    func testDragResizePersistsHeights() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])

        let beforeA = v.sectionStates[0].contentHeight
        let beforeB = v.sectionStates[1].contentHeight

        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 40,
            startHeights: (beforeA, beforeB))

        XCTAssertEqual(v.sectionStates[0].contentHeight, beforeA + 40, accuracy: 1)
        XCTAssertEqual(v.sectionStates[1].contentHeight, beforeB - 40, accuracy: 1)
    }

    // MARK: - Toggle shrink regression

    func testRepeatedToggleDoesNotShrinkHeight() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "files"), makeSection(id: "git")]
        v.updateSections(s, expandedIDs: ["files", "git"])

        let initialFiles = v.sectionStates[0].contentHeight
        let initialGit = v.sectionStates[1].contentHeight
        XCTAssertGreaterThan(initialFiles, 0)
        XCTAssertGreaterThan(initialGit, 0)

        // Toggle files 10 times — height should NOT shrink
        for i in 0..<10 {
            // Collapse files
            v.updateSections(s, expandedIDs: ["git"])
            // Re-expand files
            v.updateSections(s, expandedIDs: ["files", "git"])

            XCTAssertEqual(
                v.sectionStates[0].contentHeight, initialFiles, accuracy: 2,
                "Files height should not shrink on toggle \(i + 1)")
            XCTAssertEqual(
                v.sectionStates[1].contentHeight, initialGit, accuracy: 2,
                "Git height should not shrink on toggle \(i + 1)")
        }
    }

    func testRepeatedToggleWithDragDoesNotShrink() {
        let v = makePanelView(height: 600)
        let s = [makeSection(id: "a"), makeSection(id: "b")]
        v.updateSections(s, expandedIDs: ["a", "b"])

        // Drag to resize
        v.handleDrag(
            aboveIndex: 0, belowIndex: 1, delta: 50,
            startHeights: (v.sectionStates[0].contentHeight, v.sectionStates[1].contentHeight))
        let draggedA = v.sectionStates[0].contentHeight
        let draggedB = v.sectionStates[1].contentHeight

        // Toggle 10 times
        for i in 0..<10 {
            v.updateSections(s, expandedIDs: ["b"])
            v.updateSections(s, expandedIDs: ["a", "b"])

            XCTAssertEqual(
                v.sectionStates[0].contentHeight, draggedA, accuracy: 2,
                "A height should not shrink on toggle \(i + 1)")
            XCTAssertEqual(
                v.sectionStates[1].contentHeight, draggedB, accuracy: 2,
                "B height should not shrink on toggle \(i + 1)")
        }
    }

    func testResizeDistributesRemainingSpaceProportionally() {
        let v = makePanelView(height: 500)
        let s = [makeSection(id: "a"), makeSection(id: "b"), makeSection(id: "c")]
        v.updateSections(s, expandedIDs: ["a", "b", "c"])
        v.layoutAllSections()

        let before = v.sectionStates.map(\.contentHeight)
        v.handleDrag(
            aboveIndex: 0,
            belowIndex: 1,
            delta: 60,
            startHeights: (before[0], before[1])
        )
        let resized = v.sectionStates.map(\.contentHeight)

        v.frame.size.height = 700
        v.layoutAllSections()

        let scaleA = v.sectionStates[0].contentHeight / resized[0]
        let scaleB = v.sectionStates[1].contentHeight / resized[1]
        let scaleC = v.sectionStates[2].contentHeight / resized[2]

        XCTAssertEqual(scaleA, scaleB, accuracy: 0.02)
        XCTAssertEqual(scaleA, scaleC, accuracy: 0.02)
    }

    // MARK: - Non-growable section height

    func testNonGrowableSectionGetsIntrinsicHeight() {
        let v = makePanelView(height: 600)
        let tree = makeSection(id: "tree")
        let info = makeNonGrowableSection(id: "info")
        v.updateSections([tree, info], expandedIDs: ["tree", "info"])

        let infoHeight = v.sectionStates[1].contentHeight
        let infoIntrinsic = v.sectionStates[1].intrinsicHeight
        let expected = max(SidebarLayout.minSectionHeight, infoIntrinsic)

        // Non-growable section should stay at its intrinsic height, not be inflated
        XCTAssertEqual(
            infoHeight, expected, accuracy: 1,
            "Non-growable section should match intrinsic height, not receive extra space")

        // Growable section should absorb the remaining space
        let treeHeight = v.sectionStates[0].contentHeight
        XCTAssertGreaterThan(
            treeHeight, infoHeight,
            "Growable section should absorb remaining space")
    }

    func testOverflowShrinksPrioritizesGrowable() {
        // Very tight height: 3 headers (78) + 2 separators (2) = 80pt overhead,
        // leaving only 120pt for content with 3 expanded sections.
        let v = makePanelView(height: 200)
        let tree = makeSection(id: "tree")
        let git = makeSection(id: "git")
        let info = makeNonGrowableSection(id: "info")
        v.updateSections([tree, git, info], expandedIDs: ["tree", "git", "info"])

        let infoHeight = v.sectionStates[2].contentHeight
        let treeHeight = v.sectionStates[0].contentHeight
        let gitHeight = v.sectionStates[1].contentHeight

        // Growable sections should be at or near minimum before non-growable is touched
        let minH = SidebarLayout.minSectionHeight
        XCTAssertGreaterThanOrEqual(
            infoHeight, min(minH, v.sectionStates[2].intrinsicHeight),
            "Non-growable section should not be shrunk below intrinsic (or min)")
        // If growable sections had room to absorb all overflow, they should be at min
        if treeHeight <= minH + 1 && gitHeight <= minH + 1 {
            // Growable at minimum — non-growable may need to shrink too, that's OK
        } else {
            // Growable still above minimum — non-growable should be at intrinsic
            let infoIntrinsic = v.sectionStates[2].intrinsicHeight
            let expected = max(minH, infoIntrinsic)
            XCTAssertEqual(
                infoHeight, expected, accuracy: 2,
                "Non-growable section should stay at intrinsic when growable sections have room")
        }
    }

    func testNonGrowableHeightRestoredAfterCollapseExpand() {
        let v = makePanelView(height: 600)
        let tree = makeSection(id: "tree")
        let info = makeNonGrowableSection(id: "info")
        v.updateSections([tree, info], expandedIDs: ["tree", "info"])

        let infoHeight = v.sectionStates[1].contentHeight
        XCTAssertGreaterThan(infoHeight, 0)

        // Collapse info
        v.updateSections([tree, info], expandedIDs: ["tree"])
        XCTAssertEqual(v.sectionStates[1].contentHeight, 0)

        // Simulate async content load completing after collapse: set the saved height
        // as the KVO observer would after intrinsic size grows.
        let biggerIntrinsic: CGFloat = 150
        v.savedSectionHeights["info"] = biggerIntrinsic

        // Re-expand info — should restore to the saved height from KVO update
        v.updateSections([tree, info], expandedIDs: ["tree", "info"])
        XCTAssertEqual(
            v.sectionStates[1].contentHeight, biggerIntrinsic, accuracy: 2,
            "Non-growable section should restore to updated intrinsic after collapse/expand")
    }
}
